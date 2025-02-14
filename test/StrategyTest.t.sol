//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import {MockToken} from "./mocks/MockToken.sol";

import {Strategy} from "../src/Strategy.sol";
//Imports from aave-v3-origin //
import {IAToken, IERC20} from "lib/aave-v3-origin/src/contracts/interfaces/IAToken.sol";
import {IPool, DataTypes} from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "lib/aave-v3-origin/src/contracts/interfaces/IPoolAddressesProvider.sol";
import {PoolInstance} from "lib/aave-v3-origin/src/contracts/instances/PoolInstance.sol";
import {Errors} from "lib/aave-v3-origin/src/contracts/protocol/libraries/helpers/Errors.sol";
import {ReserveConfiguration} from "lib/aave-v3-origin/src/contracts/protocol/pool/PoolConfigurator.sol";
import {WadRayMath} from "lib/aave-v3-origin/src/contracts/protocol/libraries/math/WadRayMath.sol";
import {IAaveOracle} from "lib/aave-v3-origin/src/contracts/interfaces/IAaveOracle.sol";
import {TestnetProcedures} from "lib/aave-v3-origin/tests/utils/TestnetProcedures.sol";

//Imports from compound-protocol //
import {CTokenInterface} from "@compound-protocol/contracts/CTokenInterfaces.sol";
import {InterestRateModel} from "@compound-protocol/contracts/InterestRateModel.sol";

contract StrategyTest is TestnetProcedures {
    // AavePool setup //
    using stdStorage for StdStorage;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using WadRayMath for uint256;

    IPool internal pool;

    // Compound setup //
    MockToken public TokenSupplyRatePerBlock;

    // First flight strategy setup //
    Strategy public strategy;

    // Strategy name
    string public constant STRATEGY_NAME = "TestStrategy";

    function setUp() public {
        // Aave setup //
        initTestEnvironment();
        pool = PoolInstance(report.poolProxy);

        // Get token from aavePool test environment

        // Token for compound supplyRatePerBlock function test
        TokenSupplyRatePerBlock = new MockToken("TokenSupplyRatePerBlock", "TSRPB", 18, 1e18);
        // Strategy TestStrategy = new Strategy(_asset, _aavePool, _compoundToken, _aaveRewardsController, STRATEGY_NAME);
    }

    function testDeployContracts() public view {
        // check if the setup works fine (deploying contracts)
        uint256 wbtcAliceBalance = IERC20(tokenList.wbtc).balanceOf(alice);
        DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(tokenList.wbtc);
        uint256 liquidityRate = reserveData.currentLiquidityRate;
        console.log("liquidtyrate", liquidityRate);
        console.log("Alice's balance of WBTC: ", wbtcAliceBalance);
        assert(true);
    }

    function testCalculateAaveAPY() public {}

    function testCalculateCompoundAPY() public {}

    function testDeployFunds() public {}

    function testFreeFunds() public {}

    function testHarvestAndReport() public {}

    function testClaimAndSellRewards() public {}

    function testGetAPY() public {}
}
