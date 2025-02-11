//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IPool} from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";
import {DataTypes} from "lib/aave-v3-origin/src/contracts/protocol/libraries/types/DataTypes.sol";
import {CTokenInterface} from "@compound-protocol/contracts/CTokenInterfaces.sol";
// import {CErc20Interface} from "@compound-protocol/contracts/CTokenInterfaces.sol";

library APYCalculator {
    uint256 private constant BLOCKS_PER_YEAR = 2_628_000; // ~365 * 24 * 60 * 60 / 12
    // 1e27 is used to maintain the precision
    uint256 private constant RAY = 1e27;
    // 1e4 is used to maintain the precision - 500 represents 5.00%
    uint256 private constant PERCENTAGE_FACTOR = 1e4;

    /**
     * @notice Calculate the APY for Aave
     * @param aavePool The Aave pool
     * @param asset The asset address
     * @return The APY
     */
    function calculateAaveAPY(IPool aavePool, address asset) internal view returns (uint256) {
        // Get Struct ReserveData from Aave pool specific to the asset
        DataTypes.ReserveDataLegacy memory reserveData = aavePool.getReserveData(asset);
        // Get the current liquidity rate from the struct type Expressed in ray (1e27) eg; si taux à 5% => 5e27 (0.05*1e27)
        uint256 liquidityRate = reserveData.currentLiquidityRate;

        // Convert Aave rate to APY
        // 1. Convert rate from ray to normal rate 50__000_000_000_000_000_000_000_000 / 1e27 => 0.05 (5%)
        uint256 rate = liquidityRate / RAY;
        uint256 secondsPerYear = 365 days;
        // 2. Convert rate to APY - 1e18 used to maintain precision - taux composé annuel / si taux à 5% => 500
        uint256 apy = ((1 + rate) ** secondsPerYear - 1e18);
        // 3. Convert APY to percentage - if rate is 500 => 5%
        return (apy * PERCENTAGE_FACTOR) / 1e18;
    }

    function calculateCompoundAPY(CTokenInterface cToken) internal view returns (uint256) {
        // Get the current supply rate per block from Compound
        uint256 supplyRatePerBlock = cToken.supplyRatePerBlock();

        // Convert Compound rate to APY - 1e18 used to maintain precision - taux composé annuel / si taux à 5% => 500
        uint256 apy = ((1 + supplyRatePerBlock) ** BLOCKS_PER_YEAR - 1e18);
        // Convert APY to percentage - if rate is 500 => 5%
        return (apy * PERCENTAGE_FACTOR) / 1e18;
    }
}
