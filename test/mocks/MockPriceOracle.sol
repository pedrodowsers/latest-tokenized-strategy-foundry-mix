// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "compound-protocol/contracts/PriceOracle.sol";
import "compound-protocol/contracts/CToken.sol";

contract MockPriceOracle is PriceOracle {
    mapping(address => uint256) private prices;

    function getUnderlyingPrice(CToken cToken) external view override returns (uint256) {
        return prices[address(cToken)];
    }

    function setUnderlyingPrice(address cToken, uint256 price) external {
        prices[cToken] = price;
    }
}
