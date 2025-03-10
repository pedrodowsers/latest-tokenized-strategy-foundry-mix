// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {InterestRateModel} from "@compound-protocol/contracts/InterestRateModel.sol";

contract MockInterestRateModel is InterestRateModel {
    uint256 public constant blocksPerYear = 2628000;
    uint256 public supplyRate;

    constructor(uint256 _supplyRate) {
        supplyRate = _supplyRate;
    }

    function getBorrowRate(uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getSupplyRate(uint256, uint256, uint256, uint256) external view override returns (uint256) {
        return supplyRate;
    }
}
