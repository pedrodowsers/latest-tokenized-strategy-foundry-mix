// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IPool} from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";
import {Comptroller} from "compound-protocol/contracts/Comptroller.sol";
import {IRewardsController} from "lib/aave-v3-origin/src/contracts/rewards/interfaces/IRewardsController.sol";
import {CErc20} from "@compound-protocol/contracts/CErc20.sol";

interface IStrategyInterface is IStrategy {
    //TODO: Add your specific implementation interface in here.
    // Events
    event Strategy__RewardClaimError(address indexed asset, address indexed account);
    event Strategy__APYChecked(uint256 aaveAPY, uint256 compoundAPY, bool needsRebalance);
    event Strategy__UpkeepPerformed(uint256 timestamp);

    // View functions for immutable variables
    function i_aavePool() external view returns (IPool);
    function i_compoundToken() external view returns (CErc20);
    function i_aaveRewardsController() external view returns (IRewardsController);
    function i_comptroller() external view returns (Comptroller);

    // Constants
    function APY_THRESHOLD() external view returns (uint256);
    function MIN_CHECK_INTERVAL() external view returns (uint256);

    // State variables
    function lastAaveAPY() external view returns (uint256);
    function lastCompoundAPY() external view returns (uint256);
    function lastCheckTimestamp() external view returns (uint256);
    function lastUpkeepNeeded() external view returns (bool);

    // Keeper compatible functions (if needed)
    function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}
