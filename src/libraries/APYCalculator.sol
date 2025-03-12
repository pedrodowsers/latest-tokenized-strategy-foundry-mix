//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {console2} from "lib/forge-std/src/Test.sol";

import {IPool} from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";
import {DataTypes} from "lib/aave-v3-origin/src/contracts/protocol/libraries/types/DataTypes.sol";
import {CTokenInterface} from "@compound-protocol/contracts/CTokenInterfaces.sol";
// import {CErc20Interface} from "@compound-protocol/contracts/CTokenInterfaces.sol";
import {TestnetProcedures} from "lib/aave-v3-origin/tests/utils/TestnetProcedures.sol";
import {DefaultReserveInterestRateStrategyV2} from
    "lib/aave-v3-origin/src/contracts/misc/DefaultReserveInterestRateStrategyV2.sol";

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
        // console2.log("----------------------------------------------------------------------------");
        // console2.log("Raw liquidityRate", liquidityRate);
        // console2.log("----------------------------------------------------------------------------");
        // Convert rate from ray (1e27) to a more manageable precision (1e18)
        // If rate is 5%, liquidityRate would be 0.05 * 1e27, so we divide by 1e9 to get 0.05 * 1e18
        uint256 ratePerYear = liquidityRate / 1e9;

        // console2.log("----------------------------------------------------------------------------");
        // console2.log("Rate Per Year", ratePerYear);
        // console2.log("----------------------------------------------------------------------------");
        return ratePerYear;
    }

    function calculateCompoundAPY(CTokenInterface cToken) internal view returns (uint256) {
        // Get the current supply rate per block from Compound
        uint256 supplyRatePerBlock = cToken.supplyRatePerBlock();
        console2.log("----------------------------------------------------------------------------");
        console2.log("Raw supplyRatePerBlock from compound", supplyRatePerBlock);
        console2.log("----------------------------------------------------------------------------");

        // Calculate APY using the formula: (1 + ratePerBlock)^blocksPerYear - 1
        // We use 1e18 for precision
        uint256 annualRate = (supplyRatePerBlock * 1e19) * BLOCKS_PER_YEAR;
        console2.log("----------------------------------------------------------------------------");
        console2.log("Annual Rate from compound", annualRate);
        console2.log("----------------------------------------------------------------------------");
        // Convert to percentage (multiply by 100)
        return annualRate / 1e18;
    }

    // Helper function to calculate exponentiation with precision
    function exponentialWithPrecision(uint256 base, uint256 exponent, uint256 precision)
        internal
        pure
        returns (uint256)
    {
        if (exponent == 0) return precision;
        if (exponent == 1) return base;

        uint256 result = precision;
        uint256 factor = base;

        // Use binary exponentiation to calculate the power
        while (exponent > 0) {
            if (exponent % 2 == 1) {
                result = (result * factor) / precision;
            }
            factor = (factor * factor) / precision;
            exponent /= 2;
        }

        return result;
    }
}
