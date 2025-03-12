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
import {StrategyFactory} from "../src/StrategyFactory.sol";
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
    // Common Token from Aave and Compound

    // MockToken public commonToken;

    // Aave variables
    IPool internal pool;
    address public aCommonToken;
    IVariableDebtToken internal varDebtCommonToken;
    // Constants
    uint256 constant INITIAL_SUPPLY = 1000000e18;

    // Compound setup //
    Comptroller public comptroller;
    CErc20 public cToken;
    // MockToken public underlyingToken;
    MockInterestRateModel public interestRateModel;
    uint256 constant INITIAL_RATE = 50000; // 5% APY
    MockPriceOracle public mockOracle;

    // First flight strategy setup //
    Strategy public strategy;
    // // Strategy name
    string public constant STRATEGY_NAME = "TestStrategy";

    StrategyFactory public factory;
    address public management;
    address public performanceFeeRecipient;
    address public keeper;
    address public emergencyAdmin;

    // Aave Rewards Controller
    IRewardsController public rewardsController;

    function setUp() public {
        // Common token for Aave and Compound
        // commonToken = new MockToken("Common Token", "CTK", 18, INITIAL_SUPPLY);
        commonToken = new TestnetERC20("Common Token", "CTK", 18, address(this));
        //1. Aave setup //
        initTestEnvironment();
        pool = PoolInstance(report.poolProxy);
        // Initial supply to Aave pool
        vm.startPrank(carol);
        // commonToken.mint(carol, 100_000e18);
        // commonToken.approve(address(pool), 100_000e18);
        contracts.poolProxy.supply(address(commonToken), 100_000e18, carol, 0);
        vm.stopPrank();

        (address aToken,, address variableDebtCommonToken) =
            contracts.protocolDataProvider.getReserveTokensAddresses(address(commonToken));
        aCommonToken = aToken;
        varDebtCommonToken = IVariableDebtToken(variableDebtCommonToken);

        //2. Compound setup //
        comptroller = new Comptroller();
        interestRateModel = new MockInterestRateModel(INITIAL_RATE);
        // Deploy Compound's core contracts
        // Deploy cToken
        cToken = new CErc20();
        vm.prank(cToken.admin());
        cToken.initialize(
            address(commonToken),
            comptroller,
            interestRateModel,
            1e18, // initial exchange rate
            "Compound Test Token",
            "cTest",
            18
        );

        //setup Mock price oracle
        mockOracle = new MockPriceOracle();

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
        vm.prank(poolAdmin);
        commonToken.mint(address(this), INITIAL_SUPPLY);
        // Get the rewards controller from Aave setup
        // rewardsController = IRewardsController(contracts.poolProxy.rewardsController);
        console2.log("Rewards Controller address:", address(rewardsController));

        // Setup addresses
        management = address(0x123);
        performanceFeeRecipient = address(0x456);
        keeper = address(0x789);
        emergencyAdmin = address(0xabc);

        // Deploy factory and strategy
        factory = new StrategyFactory(management, performanceFeeRecipient, keeper, emergencyAdmin);

        // Deploy strategy through factory
        vm.prank(management);
        address strategyAddress = factory.newStrategy(
            address(commonToken), "TestStrategy", address(pool), address(cToken), address(rewardsController)
        );
        strategy = Strategy(strategyAddress);
    }

    function testTokenSetup() public {
        // Test common token basic setup
        console2.log("Common Token address:", address(commonToken));
        console2.log("Common Token balance of this:", commonToken.balanceOf(address(this)));

        // Test Aave setup for common token
        (address aToken,,) = contracts.protocolDataProvider.getReserveTokensAddresses(address(commonToken));
        console2.log("aToken address for common token:", aToken);

        // Test Compound setup for common token
        console2.log("cToken address:", address(cToken));
        console2.log("Common Token underlying in cToken:", cToken.underlying());
    }

    function testSupplyToProtocols() public {
        uint256 supplyAmount = 1000e18;

        // Supply to Aave
        vm.startPrank(carol);
        commonToken.approve(address(pool), supplyAmount);
        pool.supply(address(commonToken), supplyAmount, carol, 0);
        vm.stopPrank();

        // Supply to Compound
        commonToken.approve(address(cToken), supplyAmount);
        cToken.mint(supplyAmount);

        // Get supply balances
        (address aToken,,) = contracts.protocolDataProvider.getReserveTokensAddresses(address(commonToken));
        uint256 aaveBalance = IERC20(aToken).balanceOf(carol);
        uint256 compoundBalance = cToken.balanceOf(address(this));

        console2.log("Aave supply balance:", aaveBalance);
        console2.log("Compound supply balance:", compoundBalance);
    }

    function testCompareAPYs() public {
        // Console log Carol initial balance
        console2.log("Carol's initial balance:", commonToken.balanceOf(carol));
        uint256 supplyAmount = 2000e18;
        uint256 borrowAmount = 800e18;
        vm.startPrank(poolAdmin); // Need to be poolAdmin to mint
        commonToken.mint(carol, supplyAmount);
        commonToken.mint(bob, supplyAmount); // Bob will borrow
        vm.stopPrank();
        // console log Carol's balance after minting
        console2.log("Carol's balance after minting:", commonToken.balanceOf(carol));

        // Carol will supply to both protocols
        vm.startPrank(carol);
        commonToken.approve(address(pool), supplyAmount);
        pool.supply(address(commonToken), supplyAmount, carol, 0);
        vm.stopPrank();

        commonToken.approve(address(cToken), supplyAmount);
        cToken.mint(supplyAmount);

        // Set up borrow in Aave
        vm.startPrank(bob);
        commonToken.approve(address(pool), supplyAmount);
        // Supply collateral first
        pool.supply(address(commonToken), supplyAmount, bob, 0);
        // Then borrow
        pool.borrow(address(commonToken), borrowAmount, 2, 0, bob);
        vm.stopPrank();

        // Set up borrowing in Compound
        // Enter markets to enable borrowing
        address[] memory markets = new address[](1);
        markets[0] = address(cToken);
        comptroller.enterMarkets(markets);

        commonToken.approve(address(cToken), supplyAmount);
        cToken.mint(supplyAmount);
        cToken.borrow(borrowAmount);

        // Get initial APYs
        uint256 aaveAPY = APYCalculator.calculateAaveAPY(contracts.poolProxy, address(commonToken));
        uint256 compoundAPY = APYCalculator.calculateCompoundAPY(cToken);

        console2.log("Initial APYs after supply and borrow:");
        console2.log("Aave APY:", aaveAPY);
        console2.log("Compound APY:", compoundAPY);

        // Warp time and check APYs again
        vm.warp(block.timestamp + 10 days);

        commonToken.approve(address(cToken), 1e6);
        cToken.mint(1e6);

        aaveAPY = APYCalculator.calculateAaveAPY(contracts.poolProxy, address(commonToken));
        compoundAPY = APYCalculator.calculateCompoundAPY(cToken);

        console2.log("\nAPYs after 10 days:");
        console2.log("Aave APY:", aaveAPY);
        console2.log("Compound APY:", compoundAPY);

        uint256 strategyAmount = 1000e18;

        //Mint tokens to strategy
        vm.startPrank(poolAdmin);
        commonToken.mint(address(strategy), strategyAmount);
        vm.stopPrank();

        //Deply funds through strategy
        vm.prank(address(strategy));
        strategy.deployFundsForVault(strategyAmount);
    }

    function testDeployFundsWithAPY() public {
        uint256 supplyAmount = 2000e18;
        uint256 borrowAmount = 800e18; // 40% of supply

        vm.startPrank(poolAdmin);
        commonToken.mint(carol, supplyAmount);
        commonToken.mint(address(this), supplyAmount);
        vm.stopPrank();

        // Setup for Compound borrowing
        address[] memory markets = new address[](1);
        markets[0] = address(cToken);
        comptroller.enterMarkets(markets);

        // Approve and supply to Compound
        commonToken.approve(address(cToken), supplyAmount);
        cToken.mint(supplyAmount);

        uint256 balanceBeforeBorrow = commonToken.balanceOf(address(this));
        console2.log("Balance before Compound borrow: ", balanceBeforeBorrow);

        cToken.borrow(borrowAmount);

        uint256 balanceAfterBorrow = commonToken.balanceOf(address(this));
        console2.log("Balance after Compound borrow: ", balanceAfterBorrow);

        // Supply and borrow in Aave
        vm.startPrank(carol);
        commonToken.approve(address(pool), supplyAmount);
        pool.supply(address(commonToken), supplyAmount, carol, 0);
        pool.borrow(address(commonToken), borrowAmount, 2, 0, carol);
        vm.stopPrank();

        // Now test strategy's _deployFunds
        uint256 strategyAmount = 1000e18;

        // Store initial balances
        uint256 initialTokenBalance = commonToken.balanceOf(address(strategy));
        uint256 initialAaveBalance = IERC20(aCommonToken).balanceOf(address(strategy));
        uint256 initialCompoundBalance = cToken.balanceOf(address(strategy));

        // Mint tokens to strategy
        vm.startPrank(poolAdmin);
        commonToken.mint(address(strategy), strategyAmount);
        vm.stopPrank();

        // Check initial strategy balances
        console2.log("\nStrategy initial balances:");
        console2.log("Token balance:", commonToken.balanceOf(address(strategy)));
        console2.log("Aave supply:", IERC20(aCommonToken).balanceOf(address(strategy)));
        console2.log("Compound supply:", cToken.balanceOf(address(strategy)));

        // Deploy funds through strategy
        vm.prank(address(management));
        strategy.deployFundsForVault(strategyAmount);

        // Get final balances
        uint256 finalTokenBalance = commonToken.balanceOf(address(strategy));
        uint256 finalAaveBalance = IERC20(aCommonToken).balanceOf(address(strategy));
        uint256 finalCompoundBalance = cToken.balanceOf(address(strategy));

        // Check final strategy balances
        console2.log("\nStrategy final balances:");
        console2.log("Token balance:", commonToken.balanceOf(address(strategy)));
        console2.log("Aave supply:", IERC20(aCommonToken).balanceOf(address(strategy)));
        console2.log("Compound supply:", cToken.balanceOf(address(strategy)));

        // Get final APYs
        uint256 aaveAPY = APYCalculator.calculateAaveAPY(contracts.poolProxy, address(commonToken));
        uint256 compoundAPY = APYCalculator.calculateCompoundAPY(cToken);

        // 1. Verify all funds were deployed (no tokens left in strategy)
        assertEq(finalTokenBalance, 0, "Strategy should have deployed all tokens");
        // 2. Verify funds were deployed to the protocol with higher APY
        if (aaveAPY > compoundAPY) {
            assertGt(finalAaveBalance, initialAaveBalance, "Funds should have been deployed to Aave");
            assertEq(finalAaveBalance - initialAaveBalance, strategyAmount, "All funds should be in Aave");
            assertEq(finalCompoundBalance, initialCompoundBalance, "No funds should have gone to Compound");
        } else {
            assertGt(finalCompoundBalance, initialCompoundBalance, "Funds should have been deployed to Compound");
            assertEq(
                cToken.balanceOf(address(strategy)) - initialCompoundBalance,
                strategyAmount,
                "All funds should be in Compound"
            );
            assertEq(finalAaveBalance, initialAaveBalance, "No funds should have gone to Aave");
        }
        // 3. Verify total value deployed matches initial amount
        uint256 totalValueDeployed =
            (finalAaveBalance - initialAaveBalance) + (finalCompoundBalance - initialCompoundBalance);
        assertEq(totalValueDeployed, strategyAmount, "Total deployed value should match initial amount");
    }

    function testFreeFunds() public {}

    function testHarvestAndReport() public {}

    function testClaimAndSellRewards() public {}

    function testGetAPY() public {}
}
