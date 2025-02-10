// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {IPool} from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";
import {IRewardsController} from "lib/aave-v3-origin/src/contracts/rewards/interfaces/IRewardsController.sol";
import {CErc20} from "@compound-protocol/contracts/CErc20.sol";
import {Comptroller} from "@compound-protocol/contracts/Comptroller.sol";
import {CToken} from "@compound-protocol/contracts/CToken.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UniswapV2Swapper} from "@periphery/swappers/UniswapV2Swapper.sol";
import {KeeperCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol";
import {APYCalculator} from "./libraries/APYCalculator.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specific storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be updated post deployment will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement, onlyEmergencyAuthorized and onlyKeepers modifiers

contract Strategy is BaseStrategy, UniswapV2Swapper, KeeperCompatibleInterface {
    using SafeERC20 for ERC20;

    // Events
    event Strategy__RewardClaimError(address indexed asset, address indexed account);
    event Strategy__APYChecked(uint256 aaveAPY, uint256 compoundAPY, bool needsRebalance);
    event Strategy__UpkeepPerformed(uint256 timestamp);

    IPool public immutable i_aavePool;
    CErc20 public immutable i_compoundToken;
    IRewardsController public immutable i_aaveRewardsController;
    Comptroller public immutable i_comptroller;

    // Constants for chainlink keeper
    uint256 public constant APY_THRESHOLD = 500; // 5% in basis points
    uint256 public constant MIN_CHECK_INTERVAL = 1 hours;

    // State variables for chainlink keeper functions
    uint256 public lastAaveAPY;
    uint256 public lastCompoundAPY;
    uint256 public lastCheckTimestamp;
    bool public lastUpkeepNeeded;

    constructor(
        address _asset,
        address _aavePool,
        address _compoundToken,
        address _aaveRewardsController,
        string memory _name
    ) BaseStrategy(_asset, _name) {
        i_aavePool = IPool(_aavePool);
        i_compoundToken = CErc20(_compoundToken);
        i_comptroller = Comptroller(_compoundToken);
        i_aaveRewardsController = IRewardsController(_aaveRewardsController);
        _approveTokens(_asset);
    }

    function _approveTokens(address _asset) internal {
        IERC20(_asset).approve(address(i_aavePool), type(uint256).max);
        IERC20(_asset).approve(address(i_compoundToken), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        // Get the current APY for Aave and Compound
        uint256 aaveAPY = APYCalculator.calculateAaveAPY(i_aavePool, address(asset));
        uint256 compoundAPY = APYCalculator.calculateCompoundAPY(i_compoundToken);

        if (aaveAPY > compoundAPY) {
            // Deposit on Aave
            i_aavePool.supply(address(asset), _amount, address(this), 0);
        } else {
            // Deposit on Compound
            uint256 response = i_compoundToken.mint(_amount);
            require(response == 0, "Compound mint failed");
        }
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // Get the balance from the yield source Aave or Compound
        (uint256 totalCollateralBase,,,,,) = i_aavePool.getUserAccountData(address(this));
        uint256 compoundBalance = i_compoundToken.balanceOf(address(this));

        uint256 totalBalance = totalCollateralBase + compoundBalance;
        // Check if withdrawal amount exceeds total balance and if there is no balance, return
        if (_amount > totalBalance) {
            _amount = totalBalance;
        }
        if (totalBalance == 0) return;

        // Calculate the amount to withdraw from Aave and Compound
        
        // @audit-bug Voir si on laisse ce bug, pour voir si les tests sont bien faits car on retire dans les deux pools
        //au lieu d'une seule car on dépose dans une seule pool.
        uint256 aaveWithdrawAmount = _amount * totalCollateralBase / totalBalance;
        uint256 compoundWithdrawAmount = _amount * compoundBalance / totalBalance;

        if (aaveWithdrawAmount > 0) {
            i_aavePool.withdraw(address(asset), aaveWithdrawAmount, address(this));
        }

        if (compoundWithdrawAmount > 0) {
            uint256 result = i_compoundToken.redeemUnderlying(compoundWithdrawAmount);
            require(result == 0, "Compound redeem failed");
        }
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        if (TokenizedStrategy.isShutdown()) {
            _claimAndSellRewards();
        }

        // Get the current APY for Aave and Compound
        uint256 aaveAPY = APYCalculator.calculateAaveAPY(i_aavePool, address(asset));
        uint256 compoundAPY = APYCalculator.calculateCompoundAPY(i_compoundToken);

        // Compare current APY between Aave and Compound
        if (aaveAPY > compoundAPY) {
            // Withdraw from Compound
            i_compoundToken.redeemUnderlying(i_compoundToken.balanceOf(address(this)));
            // Deposit into Aave
            i_aavePool.supply(address(asset), asset.balanceOf(address(this)), address(this), 0);
        } else {
            // Withdraw from Aave
            (uint256 totalCollateralBase,,,,,) = i_aavePool.getUserAccountData(address(this));
            i_aavePool.withdraw(address(asset), totalCollateralBase, address(this));
            // Deposit into Compound
            i_compoundToken.mint(asset.balanceOf(address(this)));
        }

        if (aaveAPY > compoundAPY) {
            (uint256 totalCollateralBase,,,,,) = i_aavePool.getUserAccountData(address(this));
            _totalAssets = totalCollateralBase;
        } else {
            _totalAssets = i_compoundToken.balanceOfUnderlying(address(this));
        }
    }

    /**
     * @notice Claims and sells rewards from Aave protocol
     * @dev Claims rewards using the RewardsController and optionally sells them for the underlying asset
     */
    function _claimAndSellRewards() internal {
        // Check if we have any deposits in Aave
        (uint256 totalCollateralBase,,,,,) = i_aavePool.getUserAccountData(address(this));

        if (totalCollateralBase > 0) {
            //@axel test unitaire -- Etre sure que cest des a token et si ce n'est pas le cas, voir si on peut le récupérer ou non.
            // Get the aToken for our asset
            address aToken = i_aavePool.getReserveData(address(asset)).aTokenAddress;

            // Setup array for claiming rewards
            address[] memory assets = new address[](1);
            assets[0] = aToken;

            // Claim all rewards
            try i_aaveRewardsController.claimAllRewards(assets, address(this))
            //@audit-bug Autre finding, pas de possibilite de withdraw les tokens en cas de shutdown //
            returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
                // Process each reward token
                for (uint256 i = 0; i < rewardsList.length; ++i) {
                    if (claimedAmounts[i] > 0) {
                        address rewardToken = rewardsList[i];
                        uint256 rewardAmount = claimedAmounts[i];

                        // If the reward token is not the same as our asset, we need to sell it
                        if (rewardToken != address(asset)) {
                            //@axel test unitaire -- Faire test d'intégration que la fct fonctionne bien.
                            // Approve the router to spend our reward tokens if needed
                            _checkAllowance(router, rewardToken, rewardAmount);

                            // Get the minimum amount out we're willing to accept
                            uint256 minAmountOut = _getAmountOut(rewardToken, address(asset), rewardAmount);
                            minAmountOut = minAmountOut * 95 / 100; // 5% max slippage

                            // Perform the swap
                            _swapFrom(rewardToken, address(asset), rewardAmount, minAmountOut);
                        }
                    }
                }
            } catch {
                // If claiming rewards fails, we just continue without claiming
                // We might want to log this for monitoring purposes
                emit Strategy__RewardClaimError(address(asset), address(this));
            }
        }
        // Check if we have any deposits in Compound
        uint256 compoundBalance = i_compoundToken.balanceOf(address(this));
        if (compoundBalance > 0) {
            // Claim COMP rewards
            CToken[] memory cTokens = new CToken[](1);
            cTokens[0] = CToken(address(i_compoundToken));
            //@axel test unitaire -- s'assurer que la fct fonctionne bien (claimcomp permet de récupérer les rewards)
            i_comptroller.claimComp(address(this), cTokens);

            // Get COMP token address
            address compToken = i_comptroller.getCompAddress();
            uint256 compBalance = IERC20(compToken).balanceOf(address(this));

            if (compBalance > 0) {
                // If we have COMP rewards, swap them for the underlying asset
                _checkAllowance(router, compToken, compBalance);

                // Get the minimum amount out we're willing to accept
                uint256 minAmountOut = _getAmountOut(compToken, address(asset), compBalance);

                // Perform the swap
                _swapFrom(compToken, address(asset), compBalance, minAmountOut);
            }
        }
    }

    /**
     * @notice Checks if the strategy needs rebalancing based on APY differences
     * @return upkeepNeeded Boolean indicating if rebalancing is needed
     * @return performData Empty bytes as no additional data is needed
     */
    function checkUpkeep(bytes calldata /* checkData */ )
        external
        override
        returns (bool upkeepNeeded, bytes memory /* performData */ )
    {
        // Early return if strategy is shutdown or time interval hasn't passed
        if (TokenizedStrategy.isShutdown() || (block.timestamp - lastCheckTimestamp) <= MIN_CHECK_INTERVAL) {
            return (false, "");
        }

        // Get current APYs
        uint256 currentAaveAPY = APYCalculator.calculateAaveAPY(i_aavePool, address(asset));
        uint256 currentCompoundAPY = APYCalculator.calculateCompoundAPY(i_compoundToken);

        // Calculate absolute APY difference
        uint256 apyDiff = currentAaveAPY > currentCompoundAPY
            ? currentAaveAPY - currentCompoundAPY
            : currentCompoundAPY - currentAaveAPY;

        // Update state
        lastAaveAPY = currentAaveAPY;
        lastCompoundAPY = currentCompoundAPY;
        lastCheckTimestamp = block.timestamp;

        // Determine if rebalance is needed
        upkeepNeeded = apyDiff > APY_THRESHOLD;
        lastUpkeepNeeded = upkeepNeeded;

        emit Strategy__APYChecked(currentAaveAPY, currentCompoundAPY, upkeepNeeded);
        return (upkeepNeeded, "");
    }

    /**
     * @notice Performs the rebalancing if conditions are met
     * @param /*performData Unused but required by interface
     */
    function performUpkeep(bytes calldata /* performData */ ) external override {
        require(!TokenizedStrategy.isShutdown(), "Strategy is shutdown");
        require(lastUpkeepNeeded, "No upkeep needed");
        require(block.timestamp - lastCheckTimestamp <= MIN_CHECK_INTERVAL * 2, "APY check too old");

        _harvestAndReport();
        emit Strategy__UpkeepPerformed(block.timestamp);
    }

    /**
     * @notice View function to get current APY difference
     * @return difference Current APY difference in basis points
     * @return needsRebalance Whether rebalancing is needed based on threshold
     */
    function currentAPYDifference() external view returns (uint256 difference, bool needsRebalance) {
        uint256 aaveAPY = APYCalculator.calculateAaveAPY(i_aavePool, address(asset));
        uint256 compoundAPY = APYCalculator.calculateCompoundAPY(i_compoundToken);

        difference = aaveAPY > compoundAPY ? aaveAPY - compoundAPY : compoundAPY - aaveAPY;

        needsRebalance = difference > APY_THRESHOLD;
    }

    /*//////////////////////////////////////////////////////////////
                    FUNCTIONS FOR STRATEGYTEST CONTRACTS
    //////////////////////////////////////////////////////////////*/

    function deployFundsForVault(uint256 amount) public {
        _deployFunds(amount);
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(yieldSource);
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(address /*_owner*/ ) public view override returns (uint256) {
        // NOTE: Withdraw limitations such as liquidity constraints should be accounted for HERE
        //  rather than _freeFunds in order to not count them as losses on withdraws.

        // TODO: If desired implement withdraw limit logic and any needed state variables.

        // EX:
        // if(yieldSource.notShutdown()) {
        //    return asset.balanceOf(address(this)) + asset.balanceOf(yieldSource);
        // }
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
     * function availableDepositLimit(
     *     address _owner
     * ) public view override returns (uint256) {
     *     TODO: If desired Implement deposit limit logic and any needed state variables .
     *
     *     EX:
     *         uint256 totalAssets = TokenizedStrategy.totalAssets();
     *         return totalAssets >= depositLimit ? 0 : depositLimit - totalAssets;
     * }
     */

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
     * function _tend(uint256 _totalIdle) internal override {}
     */

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
     * function _tendTrigger() internal view override returns (bool) {}
     */

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * function _emergencyWithdraw(uint256 _amount) internal override {
     *     TODO: If desired implement simple logic to free deployed funds.
     *
     *     EX:
     *         _amount = min(_amount, aToken.balanceOf(address(this)));
     *         _freeFunds(_amount);
     * }
     */
}
