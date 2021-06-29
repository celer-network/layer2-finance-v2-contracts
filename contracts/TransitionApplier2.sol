// SPDX-License-Identifier: MIT

// 2nd part of the transition applier due to contract size restrictions

pragma solidity 0.8.6;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/* Internal Imports */
import {DataTypes as dt} from "./libraries/DataTypes.sol";
import {Transitions as tn} from "./libraries/Transitions.sol";
import "./libraries/ErrMsg.sol";

contract TransitionApplier2 {
    uint256 public constant STAKING_SCALE_FACTOR = 1e12;

    /**********************
     * External Functions *
     **********************/

    /**
     * @notice Apply an AggregateOrdersTransition.
     *
     * @param _transition The disputed transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @return new strategy info after applying the disputed transition
     */
    function applyAggregateOrdersTransition(
        dt.AggregateOrdersTransition memory _transition,
        dt.StrategyInfo memory _strategyInfo
    ) public pure returns (dt.StrategyInfo memory) {
        uint256 npend = _strategyInfo.pending.length;
        require(npend > 0, ErrMsg.REQ_NO_PEND);
        dt.PendingStrategyInfo memory psi = _strategyInfo.pending[npend - 1];
        require(_transition.buyAmount == psi.buyAmount, ErrMsg.REQ_BAD_AMOUNT);
        require(_transition.sellShares == psi.sellShares, ErrMsg.REQ_BAD_SHARES);

        uint256 minSharesFromBuy = (_transition.buyAmount * 1e18) / psi.maxSharePriceForBuy;
        uint256 minAmountFromSell = (_transition.sellShares * psi.minSharePriceForSell) / 1e18;
        require(_transition.minSharesFromBuy == minSharesFromBuy, ErrMsg.REQ_BAD_SHARES);
        require(_transition.minAmountFromSell == minAmountFromSell, ErrMsg.REQ_BAD_AMOUNT);

        _strategyInfo.nextAggregateId++;

        return _strategyInfo;
    }

    /**
     * @notice Apply a ExecutionResultTransition.
     *
     * @param _transition The disputed transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new strategy info after applying the disputed transition
     */
    function applyExecutionResultTransition(
        dt.ExecutionResultTransition memory _transition,
        dt.StrategyInfo memory _strategyInfo,
        dt.GlobalInfo memory _globalInfo
    ) public pure returns (dt.StrategyInfo memory, dt.GlobalInfo memory) {
        uint256 idx;
        bool found = false;
        for (uint256 i = 0; i < _strategyInfo.pending.length; i++) {
            if (_strategyInfo.pending[i].aggregateId == _transition.aggregateId) {
                idx = i;
                found = true;
                break;
            }
        }
        require(found, ErrMsg.REQ_BAD_AGGR);

        if (_transition.success) {
            _strategyInfo.pending[idx].sharesFromBuy = _transition.sharesFromBuy;
            _strategyInfo.pending[idx].amountFromSell = _transition.amountFromSell;
        }
        _strategyInfo.pending[idx].executionSucceed = _transition.success;
        _strategyInfo.pending[idx].unsettledBuyAmount = _strategyInfo.pending[idx].buyAmount;
        _strategyInfo.pending[idx].unsettledSellShares = _strategyInfo.pending[idx].sellShares;
        _strategyInfo.lastExecAggregateId = _transition.aggregateId;

        // Piggy-back the update to the global epoch
        if (_transition.currEpoch > _globalInfo.currEpoch) {
            _globalInfo.currEpoch = _transition.currEpoch;
        }

        return (_strategyInfo, _globalInfo);
    }

    /**
     * @notice Apply a WithdrawProtocolFeeTransition.
     *
     * @param _transition The disputed transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new global info after applying the disputed transition
     */
    function applyWithdrawProtocolFeeTransition(
        dt.WithdrawProtocolFeeTransition memory _transition,
        dt.GlobalInfo memory _globalInfo
    ) public pure returns (dt.GlobalInfo memory) {
        _globalInfo.protoFees[_transition.assetId] -= _transition.amount;
        return _globalInfo;
    }

    /**
     * @notice Apply a TransferOperatorFeeTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account info and global info after applying the disputed transition
     */
    function applyTransferOperatorFeeTransition(
        dt.TransferOperatorFeeTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.GlobalInfo memory _globalInfo
    ) external pure returns (dt.AccountInfo memory, dt.GlobalInfo memory) {
        require(_accountInfo.accountId == _transition.accountId, ErrMsg.REQ_BAD_ACCT);
        require(_accountInfo.account != address(0), ErrMsg.REQ_BAD_ACCT);

        uint32 assetFeeLen = uint32(_globalInfo.opFees.assets.length);
        if (assetFeeLen > 1) {
            tn.adjustAccountIdleAssetEntries(_accountInfo, assetFeeLen - 1);
            for (uint256 i = 1; i < assetFeeLen; i++) {
                _accountInfo.idleAssets[i] += _globalInfo.opFees.assets[i];
                _globalInfo.opFees.assets[i] = 0;
            }
        }

        uint32 shareFeeLen = uint32(_globalInfo.opFees.shares.length);
        if (shareFeeLen > 1) {
            tn.adjustAccountShareEntries(_accountInfo, shareFeeLen - 1);
            for (uint256 i = 1; i < shareFeeLen; i++) {
                _accountInfo.shares[i] += _globalInfo.opFees.shares[i];
                _globalInfo.opFees.shares[i] = 0;
            }
        }

        return (_accountInfo, _globalInfo);
    }

    /**
     * @notice Apply a StakeTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _stakingPoolInfo The involved staking pool from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account, staking pool and global info after applying the disputed transition
     */
    function applyStakeTransition(
        dt.StakeTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StakingPoolInfo memory _stakingPoolInfo,
        dt.GlobalInfo memory _globalInfo
    )
        external
        pure
        returns (
            dt.AccountInfo memory,
            dt.StakingPoolInfo memory,
            dt.GlobalInfo memory
        )
    {
        require(
            ECDSA.recover(
                ECDSA.toEthSignedMessageHash(
                    keccak256(
                        abi.encodePacked(
                            _transition.transitionType,
                            _transition.poolId,
                            _transition.shares,
                            _transition.fee,
                            _transition.timestamp
                        )
                    )
                ),
                _transition.v,
                _transition.r,
                _transition.s
            ) == _accountInfo.account,
            ErrMsg.REQ_BAD_SIG
        );

        require(_accountInfo.accountId == _transition.accountId, ErrMsg.REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, ErrMsg.REQ_BAD_TS);
        require(_stakingPoolInfo.strategyId > 0, ErrMsg.REQ_BAD_SP);
        _accountInfo.timestamp = _transition.timestamp;

        uint32 poolId = _transition.poolId;
        uint256 feeInShares;
        (bool isCelr, uint256 fee) = tn.getFeeInfo(_transition.fee);
        if (isCelr) {
            _accountInfo.idleAssets[1] -= fee;
            tn.updateOpFee(_globalInfo, true, 1, fee);
        } else {
            feeInShares = fee;
            tn.updateOpFee(_globalInfo, false, _stakingPoolInfo.strategyId, fee);
        }
        uint256 addedShares = _transition.shares - feeInShares;

        _updatePoolStates(_stakingPoolInfo, _globalInfo);

        if (addedShares > 0) {
            _adjustAccountStakedShareAndStakeEntries(_accountInfo, poolId);
            uint256 addedStake = _getAdjustedStake(
                _accountInfo.stakedShares[poolId] + addedShares,
                _stakingPoolInfo.stakeAdjustmentFactor
            ) - _accountInfo.stakes[poolId];
            _accountInfo.stakedShares[poolId] += addedShares;
            _accountInfo.stakes[poolId] += addedStake;
            _stakingPoolInfo.totalShares += addedShares;
            _stakingPoolInfo.totalStakes += addedStake;

            for (uint32 rewardTokenId = 0; rewardTokenId < _stakingPoolInfo.rewardPerEpoch.length; rewardTokenId++) {
                _adjustAccountRewardDebtEntries(_accountInfo, poolId, rewardTokenId);
                _accountInfo.rewardDebts[poolId][rewardTokenId] +=
                    (addedStake * _stakingPoolInfo.accumulatedRewardPerUnit[rewardTokenId]) /
                    STAKING_SCALE_FACTOR;
            }
        }
        tn.adjustAccountShareEntries(_accountInfo, _stakingPoolInfo.strategyId);
        _accountInfo.shares[_stakingPoolInfo.strategyId] -= _transition.shares;

        return (_accountInfo, _stakingPoolInfo, _globalInfo);
    }

    /**
     * @notice Apply an UnstakeTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _stakingPoolInfo The involved staking pool from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account, staking pool and global info after applying the disputed transition
     */
    function applyUnstakeTransition(
        dt.UnstakeTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StakingPoolInfo memory _stakingPoolInfo,
        dt.GlobalInfo memory _globalInfo
    )
        external
        pure
        returns (
            dt.AccountInfo memory,
            dt.StakingPoolInfo memory,
            dt.GlobalInfo memory
        )
    {
        require(
            ECDSA.recover(
                ECDSA.toEthSignedMessageHash(
                    keccak256(
                        abi.encodePacked(
                            _transition.transitionType,
                            _transition.poolId,
                            _transition.shares,
                            _transition.fee,
                            _transition.timestamp
                        )
                    )
                ),
                _transition.v,
                _transition.r,
                _transition.s
            ) == _accountInfo.account,
            ErrMsg.REQ_BAD_SIG
        );

        require(_accountInfo.accountId == _transition.accountId, ErrMsg.REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, ErrMsg.REQ_BAD_TS);
        require(_stakingPoolInfo.strategyId > 0, ErrMsg.REQ_BAD_SP);
        _accountInfo.timestamp = _transition.timestamp;

        uint32 poolId = _transition.poolId;
        uint256 feeInShares;
        (bool isCelr, uint256 fee) = tn.getFeeInfo(_transition.fee);
        if (isCelr) {
            _accountInfo.idleAssets[1] -= fee;
            tn.updateOpFee(_globalInfo, true, 1, fee);
        } else {
            feeInShares = fee;
            tn.updateOpFee(_globalInfo, false, _stakingPoolInfo.strategyId, fee);
        }
        uint256 removedShares = _transition.shares;

        _updatePoolStates(_stakingPoolInfo, _globalInfo);

        if (removedShares > 0) {
            _adjustAccountStakedShareAndStakeEntries(_accountInfo, poolId);
            uint256 removedStake = _accountInfo.stakes[poolId] -
                _getAdjustedStake(
                    _accountInfo.stakedShares[poolId] - removedShares,
                    _stakingPoolInfo.stakeAdjustmentFactor
                );
            _accountInfo.stakedShares[poolId] -= removedShares;
            _accountInfo.stakes[poolId] -= removedStake;
            _stakingPoolInfo.totalShares -= removedShares;
            _stakingPoolInfo.totalStakes -= removedStake;

            for (uint32 rewardTokenId = 0; rewardTokenId < _stakingPoolInfo.rewardPerEpoch.length; rewardTokenId++) {
                _adjustAccountRewardDebtEntries(_accountInfo, poolId, rewardTokenId);
                _accountInfo.rewardDebts[poolId][rewardTokenId] -=
                    (removedStake * _stakingPoolInfo.accumulatedRewardPerUnit[rewardTokenId]) /
                    STAKING_SCALE_FACTOR;
            }
        }
        // Harvest
        for (uint32 rewardTokenId = 0; rewardTokenId < _stakingPoolInfo.rewardPerEpoch.length; rewardTokenId++) {
            uint256 accumulatedReward = (_accountInfo.stakes[poolId] *
                _stakingPoolInfo.accumulatedRewardPerUnit[rewardTokenId]) / STAKING_SCALE_FACTOR;
            uint256 pendingReward = (accumulatedReward - _accountInfo.rewardDebts[poolId][rewardTokenId]);
            _accountInfo.rewardDebts[poolId][rewardTokenId] = accumulatedReward;
            uint32 assetId = _stakingPoolInfo.rewardAssetIds[rewardTokenId];
            _globalInfo.rewards = tn.adjustUint256Array(_globalInfo.rewards, assetId);
            // Cap to available reward
            if (pendingReward > _globalInfo.rewards[assetId]) {
                pendingReward = _globalInfo.rewards[assetId];
            }
            _accountInfo.idleAssets[assetId] += pendingReward;
            _globalInfo.rewards[assetId] -= pendingReward;
        }
        tn.adjustAccountShareEntries(_accountInfo, _stakingPoolInfo.strategyId);
        _accountInfo.shares[_stakingPoolInfo.strategyId] += _transition.shares - feeInShares;

        return (_accountInfo, _stakingPoolInfo, _globalInfo);
    }

    /**
     * @notice Apply an AddPoolTransition.
     *
     * @param _transition The disputed transition.
     * @param _stakingPoolInfo The involved staking pool from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new staking pool info after applying the disputed transition
     */
    function applyAddPoolTransition(
        dt.AddPoolTransition memory _transition,
        dt.StakingPoolInfo memory _stakingPoolInfo,
        dt.GlobalInfo memory _globalInfo
    ) external pure returns (dt.StakingPoolInfo memory) {
        require(_transition.rewardAssetIds.length == _transition.rewardPerEpoch.length, ErrMsg.REQ_BAD_LEN);
        require(_stakingPoolInfo.strategyId == 0, ErrMsg.REQ_BAD_SP);
        require(_transition.startEpoch >= _globalInfo.currEpoch, ErrMsg.REQ_BAD_EPOCH);

        _stakingPoolInfo.lastRewardEpoch = _transition.startEpoch;
        _stakingPoolInfo.stakeAdjustmentFactor = _transition.stakeAdjustmentFactor;
        _stakingPoolInfo.strategyId = _transition.strategyId;
        _stakingPoolInfo.rewardAssetIds = _transition.rewardAssetIds;
        _stakingPoolInfo.accumulatedRewardPerUnit = tn.adjustUint256Array(
            _stakingPoolInfo.accumulatedRewardPerUnit,
            uint32(_transition.rewardAssetIds.length)
        );
        _stakingPoolInfo.rewardPerEpoch = _transition.rewardPerEpoch;
        return _stakingPoolInfo;
    }

    /**
     * @notice Apply an UpdatePoolTransition.
     *
     * @param _transition The disputed transition.
     * @param _stakingPoolInfo The involved staking pool from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new staking pool info after applying the disputed transition
     */
    function applyUpdatePoolTransition(
        dt.UpdatePoolTransition memory _transition,
        dt.StakingPoolInfo memory _stakingPoolInfo,
        dt.GlobalInfo memory _globalInfo
    ) external pure returns (dt.StakingPoolInfo memory) {
        require(_transition.rewardPerEpoch.length == _stakingPoolInfo.rewardPerEpoch.length, ErrMsg.REQ_BAD_LEN);
        require(_stakingPoolInfo.strategyId > 0, ErrMsg.REQ_BAD_SP);

        _updatePoolStates(_stakingPoolInfo, _globalInfo);

        _stakingPoolInfo.rewardPerEpoch = _transition.rewardPerEpoch;
        return _stakingPoolInfo;
    }

    /**
     * @notice Apply a DepositRewardTransition.
     *
     * @param _transition The disputed transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new global info after applying the disputed transition
     */
    function applyDepositRewardTransition(
        dt.DepositRewardTransition memory _transition,
        dt.GlobalInfo memory _globalInfo
    ) public pure returns (dt.GlobalInfo memory) {
        _globalInfo.rewards = tn.adjustUint256Array(_globalInfo.rewards, _transition.assetId);
        _globalInfo.rewards[_transition.assetId] += _transition.amount;
        return _globalInfo;
    }

    /*********************
     * Private Functions *
     *********************/

    function _updatePoolStates(dt.StakingPoolInfo memory _stakingPoolInfo, dt.GlobalInfo memory _globalInfo)
        private
        pure
    {
        if (_globalInfo.currEpoch > _stakingPoolInfo.lastRewardEpoch) {
            uint256 totalStakes = _stakingPoolInfo.totalStakes;
            if (totalStakes > 0) {
                uint64 numEpochs = _globalInfo.currEpoch - _stakingPoolInfo.lastRewardEpoch;
                for (
                    uint32 rewardTokenId = 0;
                    rewardTokenId < _stakingPoolInfo.rewardPerEpoch.length;
                    rewardTokenId++
                ) {
                    uint256 pendingReward = numEpochs * _stakingPoolInfo.rewardPerEpoch[rewardTokenId];
                    _stakingPoolInfo.accumulatedRewardPerUnit[rewardTokenId] += ((pendingReward *
                        STAKING_SCALE_FACTOR) / totalStakes);
                }
            }
            _stakingPoolInfo.lastRewardEpoch = _globalInfo.currEpoch;
        }
    }

    /**
     * Helper to expand the account array of staked shares and stakes if needed.
     */
    function _adjustAccountStakedShareAndStakeEntries(dt.AccountInfo memory _accountInfo, uint32 poolId) private pure {
        uint32 n = uint32(_accountInfo.stakedShares.length);
        if (n <= poolId) {
            uint256[] memory arr = new uint256[](poolId + 1);
            for (uint32 i = 0; i < n; i++) {
                arr[i] = _accountInfo.stakedShares[i];
            }
            for (uint32 i = n; i <= poolId; i++) {
                arr[i] = 0;
            }
            _accountInfo.stakedShares = arr;
        }
        n = uint32(_accountInfo.stakes.length);
        if (n <= poolId) {
            uint256[] memory arr = new uint256[](poolId + 1);
            for (uint32 i = 0; i < n; i++) {
                arr[i] = _accountInfo.stakes[i];
            }
            for (uint32 i = n; i <= poolId; i++) {
                arr[i] = 0;
            }
            _accountInfo.stakes = arr;
        }
    }

    /**
     * Helper to expand the 2D array of account reward debt entries per pool and reward token IDs.
     */
    function _adjustAccountRewardDebtEntries(
        dt.AccountInfo memory _accountInfo,
        uint32 poolId,
        uint32 rewardTokenId
    ) private pure {
        uint32 n = uint32(_accountInfo.rewardDebts.length);
        if (n <= poolId) {
            uint256[][] memory rewardDebts = new uint256[][](poolId + 1);
            for (uint32 i = 0; i < n; i++) {
                rewardDebts[i] = _accountInfo.rewardDebts[i];
            }
            for (uint32 i = n; i < poolId; i++) {
                rewardDebts[i] = new uint256[](0);
            }
            rewardDebts[poolId] = new uint256[](rewardTokenId + 1);
            _accountInfo.rewardDebts = rewardDebts;
        }
        uint32 nRewardTokens = uint32(_accountInfo.rewardDebts[poolId].length);
        if (nRewardTokens <= rewardTokenId) {
            uint256[] memory debts = new uint256[](rewardTokenId + 1);
            for (uint32 i = 0; i < nRewardTokens; i++) {
                debts[i] = _accountInfo.rewardDebts[poolId][i];
            }
            for (uint32 i = nRewardTokens; i <= rewardTokenId; i++) {
                debts[i] = 0;
            }
            _accountInfo.rewardDebts[poolId] = debts;
        }
    }

    /**
     * @notice Calculates the adjusted stake from staked shares.
     * @param _stakedShares The staked shares
     * @param _adjustmentFactor The adjustment factor, a value from (0, 1) * STAKING_SCALE_FACTOR
     */
    function _getAdjustedStake(uint256 _stakedShares, uint256 _adjustmentFactor) private pure returns (uint256) {
        return
            ((STAKING_SCALE_FACTOR - _adjustmentFactor) *
                _stakedShares +
                _sqrt(STAKING_SCALE_FACTOR * _adjustmentFactor * _stakedShares)) / STAKING_SCALE_FACTOR;
    }

    /**
     * @notice Implements square root with Babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method).
     * @param _y The input
     */
    function _sqrt(uint256 _y) private pure returns (uint256) {
        uint256 z;
        if (_y > 3) {
            z = _y;
            uint256 x = _y / 2 + 1;
            while (x < z) {
                z = x;
                x = (_y / x + x) / 2;
            }
        } else if (_y != 0) {
            z = 1;
        }
        return z;
    }
}
