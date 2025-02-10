//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from 'forge-std/Test.sol';
import {StdStorage} from 'forge-std/StdStorage.sol';

import {Strategy} from '../src/Strategy.sol';

import {IAToken, IERC20} from 'lib/aave-v3-origin/src/contracts/interfaces/IAToken.sol';
import {IPool, DataTypes} from 'lib/aave-v3-origin/src/contracts/interfaces/IPool.sol';
import {IPoolAddressesProvider} from 'lib/aave-v3-origin/src/contracts/interfaces/IPoolAddressesProvider.sol';
import {PoolInstance} from 'lib/aave-v3-origin/src/contracts/instances/PoolInstance.sol';
import {Errors} from 'lib/aave-v3-origin/src/contracts/protocol/libraries/helpers/Errors.sol';
import {ReserveConfiguration} from 'lib/aave-v3-origin/src/contracts/protocol/pool/PoolConfigurator.sol';
import {WadRayMath} from 'lib/aave-v3-origin/src/contracts/protocol/libraries/math/WadRayMath.sol';
import {IAaveOracle} from 'lib/aave-v3-origin/src/contracts/interfaces/IAaveOracle.sol';
import {TestnetProcedures} from 'lib/aave-v3-origin/tests/utils/TestnetProcedures.sol';

contract StrategyTest {

    function setUp() public {}

    function testCalculateAaveAPY() public{}

    function testCalculateCompoundAPY() public{}

    function testDeployFunds() public{}

    function testFreeFunds() public{}

    function testHarvestAndReport() public{}

    function testClaimAndSellRewards() public{}

    function testGetAPY() public{}
}