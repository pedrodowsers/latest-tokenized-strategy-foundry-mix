//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console2} from "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
//mocks
import {MockToken} from "./mocks/MockToken.sol";
import {MockInterestRateModel} from "./mocks/MockInterestRateModel.sol";
//strategy
import {Strategy} from "../src/Strategy.sol";
import {APYCalculator} from "../src/libraries/APYCalculator.sol";
//Imports from aave-v3-origin //
import {IAToken, IERC20} from "lib/aave-v3-origin/src/contracts/interfaces/IAToken.sol";
import {IPool, DataTypes} from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "lib/aave-v3-origin/src/contracts/interfaces/IPoolAddressesProvider.sol";
import {PoolInstance} from "lib/aave-v3-origin/src/contracts/instances/PoolInstance.sol";
import {Errors} from "lib/aave-v3-origin/src/contracts/protocol/libraries/helpers/Errors.sol";
import {ReserveConfiguration} from "lib/aave-v3-origin/src/contracts/protocol/pool/PoolConfigurator.sol";
import {WadRayMath} from "lib/aave-v3-origin/src/contracts/protocol/libraries/math/WadRayMath.sol";
import {IAaveOracle} from "lib/aave-v3-origin/src/contracts/interfaces/IAaveOracle.sol";
import {TestnetProcedures, TestReserveConfig} from "lib/aave-v3-origin/tests/utils/TestnetProcedures.sol";
import {IRewardsController} from "lib/aave-v3-origin/src/contracts/rewards/interfaces/IRewardsController.sol";
import {TestnetERC20, IERC20WithPermit} from "lib/aave-v3-origin/tests/utils/TestnetProcedures.sol";
import {EIP712SigUtils} from "lib/aave-v3-origin/tests/utils/EIP712SigUtils.sol";
import {IVariableDebtToken} from "lib/aave-v3-origin/src/contracts/interfaces/IVariableDebtToken.sol";
import {IReserveInterestRateStrategy} from
    "lib/aave-v3-origin/src/contracts/interfaces/IReserveInterestRateStrategy.sol";

//compound
import {CErc20} from "@compound-protocol/contracts/CErc20.sol";
import {Comptroller} from "@compound-protocol/contracts/Comptroller.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

contract StrategyTest is TestnetProcedures {
    // AavePool setup //
    using stdStorage for StdStorage;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using WadRayMath for uint256;

    address internal aUSDX;
    address internal aWBTC;
    IPool internal pool;

    // Compound setup //
    Comptroller public comptroller;
    CErc20 public cToken;
    MockToken public underlyingToken;
    MockInterestRateModel public interestRateModel;
    MockPriceOracle public mockOracle;

    // First flight strategy setup //
    Strategy public strategy;
    // Strategy name
    string public constant STRATEGY_NAME = "TestStrategy";
    // Common Token from Aave and Compound
    // MockToken public commonToken;

    // Constants
    uint256 constant INITIAL_SUPPLY = 1000000e18;
    uint256 constant INITIAL_RATE = 50000; // 5% APY
    IVariableDebtToken internal varDebtUSDX;

    // Aave Rewards Controller
    IRewardsController public rewardsController;

    function setUp() public {
        // Common token for Aave and Compound
        // commonToken = new MockToken("Common Token", "CTK", 18, INITIAL_SUPPLY);
        commonToken = new TestnetERC20("Common Token", "CTK", 18, address(this));

        //1. Aave setup //
        initTestEnvironment();
        pool = PoolInstance(report.poolProxy);
        (aUSDX,,) = contracts.protocolDataProvider.getReserveTokensAddresses(tokenList.usdx);
        (aWBTC,,) = contracts.protocolDataProvider.getReserveTokensAddresses(tokenList.wbtc);
        (address atoken,, address variableDebtUSDX) =
            contracts.protocolDataProvider.getReserveTokensAddresses(tokenList.usdx);
        aUSDX = atoken;
        varDebtUSDX = IVariableDebtToken(variableDebtUSDX);
        vm.startPrank(carol);
        contracts.poolProxy.supply(tokenList.usdx, 100_000e6, carol, 0);
        vm.stopPrank();

        //2. Compound setup //
        underlyingToken = new MockToken("MockToken", "MTK", 18, INITIAL_SUPPLY);
        // Deploy Compound's core contracts
        comptroller = new Comptroller();
        interestRateModel = new MockInterestRateModel(INITIAL_RATE);
        // Deploy cToken
        cToken = new CErc20();
        vm.prank(cToken.admin());
        cToken.initialize(
            address(underlyingToken),
            comptroller,
            interestRateModel,
            1e18, // initial exchange rate
            "Compound Test Token",
            "cTest",
            18
        );
        //setup Mock price oracle
        mockOracle = new MockPriceOracle();
        // Setup Comptroller
        comptroller._supportMarket(cToken);

        // Set the price oracle
        vm.startPrank(comptroller.admin());
        comptroller._setPriceOracle(mockOracle);
        mockOracle.setUnderlyingPrice(address(cToken), 1e18); // Set initial 1:1 price ratio
        comptroller._supportMarket(cToken);
        comptroller._setCollateralFactor(cToken, 0.75e18); // Set collateral factor to 75%
        comptroller._setCloseFactor(0.5e18); // Set close factor to 50%
        comptroller._setLiquidationIncentive(1.08e18); // Set liquidation incentive to 108%
        vm.stopPrank();
        // Mint initial tokens
        underlyingToken.mint(address(this), INITIAL_SUPPLY);
        //3. Strategy setup //
        strategy = new Strategy(
            address(underlyingToken), address(pool), address(cToken), address(rewardsController), STRATEGY_NAME
        );
    }

    function testCalculateAaveAPY() public {
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 800e6;

        vm.startPrank(alice);
        contracts.poolProxy.supply(tokenList.usdx, supplyAmount, alice, 0);
        uint256 balanceBeforeBorrow = usdx.balanceOf(alice);
        console2.log("Alice USDX balance before borrow: ", balanceBeforeBorrow);
        uint256 balanceAfterSupply = usdx.balanceOf(alice);
        console2.log("Alice USDX balance after supply: ", balanceAfterSupply);
        uint256 debtBalanceBefore = varDebtUSDX.scaledBalanceOf(alice);
        console2.log("Alice USDX debt balance before borrow: ", debtBalanceBefore);

        contracts.poolProxy.borrow(tokenList.usdx, borrowAmount, 2, 0, alice);
        vm.stopPrank();

        uint256 balanceAfter = usdx.balanceOf(alice);
        uint256 debtBalanceAfter = varDebtUSDX.scaledBalanceOf(alice);

        assertEq(balanceAfter, balanceBeforeBorrow + borrowAmount);
        assertEq(debtBalanceAfter, debtBalanceBefore + borrowAmount);

        vm.warp(block.timestamp + 10 days);
        console2.log("-------------------10 days after-------------------");

        vm.startPrank(alice);
        contracts.poolProxy.supply(tokenList.usdx, 1e6, alice, 0);
        vm.stopPrank();
        // Get the APY for USDX from Aave
        console2.log("APY for USDX from Aave: ", APYCalculator.calculateAaveAPY(contracts.poolProxy, tokenList.usdx));
    }

    function testCalculateCompoundAPY() public {
        // Deploy and setup mock price oracle
        mockOracle = new MockPriceOracle();

        // Need to be admin to set price oracle
        vm.startPrank(comptroller.admin());
        comptroller._setPriceOracle(mockOracle);
        mockOracle.setUnderlyingPrice(address(cToken), 1e18); // 1:1 price ratio
        vm.stopPrank();

        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 800e6;

        // Enter markets first
        address[] memory markets = new address[](1);
        markets[0] = address(cToken);
        comptroller.enterMarkets(markets);

        // Approve and mint cTokens
        underlyingToken.approve(address(cToken), supplyAmount);
        cToken.mint(supplyAmount);

        uint256 balanceBeforeBorrow = underlyingToken.balanceOf(address(this));
        console2.log("Underlying token balance before borrow: ", balanceBeforeBorrow);

        // Borrow tokens
        cToken.borrow(borrowAmount);

        uint256 balanceAfterBorrow = underlyingToken.balanceOf(address(this));
        console2.log("Underlying token balance after borrow: ", balanceAfterBorrow);

        // Assert balances
        assertEq(balanceAfterBorrow, balanceBeforeBorrow + borrowAmount);

        // Warp time to simulate interest accrual
        vm.warp(block.timestamp + 10 days);
        console2.log("-------------------10 days after-------------------");

        // Supply more tokens to accrue interest
        underlyingToken.approve(address(cToken), 1e6);
        cToken.mint(1e6);

        // Get the APY for the underlying token from Compound
        uint256 apy = APYCalculator.calculateCompoundAPY(cToken);
        console2.log("APY for underlying token from Compound: ", apy);
    }

    function testDeployFunds() public {}

    function testFreeFunds() public {}

    function testHarvestAndReport() public {}

    function testClaimAndSellRewards() public {}

    function testGetAPY() public {}
}
