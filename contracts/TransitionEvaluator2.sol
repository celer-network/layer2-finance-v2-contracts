// SPDX-License-Identifier: MIT

// 2nd part of the transition evaluator due to contract size restrictions
// Note: only put transitions not directly needed by the RollupChain contract.

pragma solidity >=0.8.0 <0.9.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/* Internal Imports */
import {DataTypes as dt} from "./libraries/DataTypes.sol";
import {Transitions as tn} from "./libraries/Transitions.sol";
import {Transitions2 as tn2} from "./libraries/Transitions2.sol";
import "./Registry.sol";
import "./strategies/interfaces/IStrategy.sol";

contract TransitionEvaluator2 {
    // require() error messages
    string constant REQ_ST_NOT_EMPTY = "strategy not empty";
    string constant REQ_BAD_ACCT = "wrong account";
    string constant REQ_BAD_ST = "wrong strategy";
    string constant REQ_BAD_SIG = "invalid signature";
    string constant REQ_BAD_TS = "old timestamp";
    string constant REQ_NO_PEND = "no pending info";
    string constant REQ_BAD_AGGR = "wrong aggregate ID";

    uint128 public constant UINT128_MAX = 2**128 - 1;

    uint256 public constant STAKING_SCALE_FACTOR = 1e12;

    /**********************
     * External Functions *
     **********************/

    /**
     * @notice Apply a BuyTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account, strategy info, and global info after applying the disputed transition
     */
    function applyBuyTransition(
        dt.BuyTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StrategyInfo memory _strategyInfo,
        dt.GlobalInfo memory _globalInfo,
        Registry _registry
    )
        public
        view
        returns (
            dt.AccountInfo memory,
            dt.StrategyInfo memory,
            dt.GlobalInfo memory
        )
    {
        bytes32 txHash =
            keccak256(
                abi.encodePacked(
                    _transition.transitionType,
                    _transition.strategyId,
                    _transition.amount,
                    _transition.fee,
                    _transition.maxSharePrice,
                    _transition.timestamp
                )
            );
        require(
            ECDSA.recover(ECDSA.toEthSignedMessageHash(txHash), _transition.v, _transition.r, _transition.s) ==
                _accountInfo.account,
            REQ_BAD_SIG
        );

        require(_accountInfo.accountId == _transition.accountId, REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, REQ_BAD_TS);
        _accountInfo.timestamp = _transition.timestamp;

        if (_strategyInfo.assetId == 0) {
            // first time commit of new strategy
            require(_strategyInfo.shareSupply == 0, REQ_ST_NOT_EMPTY);
            require(_strategyInfo.nextAggregateId == 0, REQ_ST_NOT_EMPTY);
            require(_strategyInfo.lastExecAggregateId == 0, REQ_ST_NOT_EMPTY);
            require(_strategyInfo.pending.length == 0, REQ_ST_NOT_EMPTY);

            address strategyAddr = _registry.strategyIndexToAddress(_transition.strategyId);
            address assetAddr = IStrategy(strategyAddr).getAssetAddress();
            _strategyInfo.assetId = _registry.assetAddressToIndex(assetAddr);
        }

        uint256 npend = _strategyInfo.pending.length;
        if (npend == 0 || _strategyInfo.pending[npend - 1].aggregateId != _strategyInfo.nextAggregateId) {
            dt.PendingStrategyInfo[] memory pends = new dt.PendingStrategyInfo[](npend + 1);
            for (uint32 i = 0; i < npend; i++) {
                pends[i] = _strategyInfo.pending[i];
            }
            pends[npend].aggregateId = _strategyInfo.nextAggregateId;
            pends[npend].maxSharePriceForBuy = _transition.maxSharePrice;
            pends[npend].minSharePriceForSell = 0;
            npend++;
            _strategyInfo.pending = pends;
        } else if (_strategyInfo.pending[npend - 1].maxSharePriceForBuy > _transition.maxSharePrice) {
            _strategyInfo.pending[npend - 1].maxSharePriceForBuy = _transition.maxSharePrice;
        }

        uint256 amount = _transition.amount;
        (bool isCelr, uint256 fee) = tn2.getFeeInfo(_transition.fee, _transition.reducedFee);
        if (isCelr) {
            tn2.adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] -= fee;
            tn2.updateProtoFee(_globalInfo, true, true, 1, fee);
        } else {
            amount -= fee;
            tn2.adjustAccountIdleAssetEntries(_accountInfo, _strategyInfo.assetId);
            _accountInfo.idleAssets[_strategyInfo.assetId] -= amount;
            tn2.updateProtoFee(_globalInfo, true, true, _strategyInfo.assetId, fee);
        }

        _strategyInfo.pending[npend - 1].buyAmount += amount;

        _adjustAccountPendingEntries(_accountInfo, _transition.strategyId, _strategyInfo.nextAggregateId);
        npend = _accountInfo.pending[_transition.strategyId].length;
        _accountInfo.pending[_transition.strategyId][npend - 1].buyAmount += amount;
        if (isCelr) {
            _accountInfo.pending[_transition.strategyId][npend - 1].celrFees += fee;
        } else {
            _accountInfo.pending[_transition.strategyId][npend - 1].buyFees += fee;
        }

        return (_accountInfo, _strategyInfo, _globalInfo);
    }

    /**
     * @notice Apply a SellTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account, strategy info, and global info after applying the disputed transition
     */
    function applySellTransition(
        dt.SellTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StrategyInfo memory _strategyInfo,
        dt.GlobalInfo memory _globalInfo
    )
        external
        pure
        returns (
            dt.AccountInfo memory,
            dt.StrategyInfo memory,
            dt.GlobalInfo memory
        )
    {
        bytes32 txHash =
            keccak256(
                abi.encodePacked(
                    _transition.transitionType,
                    _transition.strategyId,
                    _transition.shares,
                    _transition.fee,
                    _transition.minSharePrice,
                    _transition.timestamp
                )
            );
        require(
            ECDSA.recover(ECDSA.toEthSignedMessageHash(txHash), _transition.v, _transition.r, _transition.s) ==
                _accountInfo.account,
            REQ_BAD_SIG
        );

        require(_accountInfo.accountId == _transition.accountId, REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, REQ_BAD_TS);
        _accountInfo.timestamp = _transition.timestamp;

        uint256 npend = _strategyInfo.pending.length;
        if (npend == 0 || _strategyInfo.pending[npend - 1].aggregateId != _strategyInfo.nextAggregateId) {
            dt.PendingStrategyInfo[] memory pends = new dt.PendingStrategyInfo[](npend + 1);
            for (uint32 i = 0; i < npend; i++) {
                pends[i] = _strategyInfo.pending[i];
            }
            pends[npend].aggregateId = _strategyInfo.nextAggregateId;
            pends[npend].maxSharePriceForBuy = UINT128_MAX;
            pends[npend].minSharePriceForSell = _transition.minSharePrice;
            npend++;
            _strategyInfo.pending = pends;
        } else if (_strategyInfo.pending[npend - 1].minSharePriceForSell < _transition.minSharePrice) {
            _strategyInfo.pending[npend - 1].minSharePriceForSell = _transition.minSharePrice;
        }

        (bool isCelr, uint256 fee) = tn2.getFeeInfo(_transition.fee, _transition.reducedFee);
        if (isCelr) {
            tn2.adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] -= fee;
            tn2.updateProtoFee(_globalInfo, true, true, 1, fee);
        }

        uint32 stId = _transition.strategyId;
        _accountInfo.shares[stId] -= _transition.shares;
        _strategyInfo.pending[npend - 1].sellShares += _transition.shares;

        _adjustAccountPendingEntries(_accountInfo, stId, _strategyInfo.nextAggregateId);
        npend = _accountInfo.pending[stId].length;
        _accountInfo.pending[stId][npend - 1].sellShares += _transition.shares;
        if (isCelr) {
            _accountInfo.pending[stId][npend - 1].celrFees += fee;
        } else {
            _accountInfo.pending[stId][npend - 1].sellFees += fee;
        }

        return (_accountInfo, _strategyInfo, _globalInfo);
    }

    /**
     * @notice Apply a SettlementTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account, strategy info, and global info after applying the disputed transition
     */
    function applySettlementTransition(
        dt.SettlementTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StrategyInfo memory _strategyInfo,
        dt.GlobalInfo memory _globalInfo
    )
        external
        pure
        returns (
            dt.AccountInfo memory,
            dt.StrategyInfo memory,
            dt.GlobalInfo memory
        )
    {
        uint32 stId = _transition.strategyId;
        uint32 assetId = _strategyInfo.assetId;
        uint64 aggrId = _transition.aggregateId;
        require(aggrId <= _strategyInfo.lastExecAggregateId, REQ_BAD_AGGR);
        require(_strategyInfo.pending.length > 0, REQ_NO_PEND);
        require(aggrId == _strategyInfo.pending[0].aggregateId, REQ_BAD_AGGR);
        require(_accountInfo.pending.length > stId, REQ_BAD_ST);
        require(_accountInfo.pending[stId].length > 0, REQ_NO_PEND);
        require(aggrId == _accountInfo.pending[stId][0].aggregateId, REQ_BAD_AGGR);

        dt.PendingStrategyInfo memory stPend = _strategyInfo.pending[0];
        dt.PendingAccountInfo memory acctPend = _accountInfo.pending[stId][0];

        if (stPend.executionSucceed) {
            if (acctPend.buyAmount > 0) {
                _adjustAccountShareEntries(_accountInfo, stId);
                uint256 shares = (acctPend.buyAmount * stPend.sharesFromBuy) / stPend.buyAmount;
                _accountInfo.shares[stId] += shares;
                stPend.unsettledBuyAmount -= acctPend.buyAmount;
            }
            if (acctPend.sellShares > 0) {
                tn2.adjustAccountIdleAssetEntries(_accountInfo, assetId);
                uint256 amount = (acctPend.sellShares * stPend.amountFromSell) / stPend.sellShares;
                uint256 fee = acctPend.sellFees;
                if (amount < fee) {
                    fee = amount;
                }
                amount -= fee;
                tn2.updateProtoFee(_globalInfo, true, false, assetId, fee);
                _accountInfo.idleAssets[assetId] += amount;
                stPend.unsettledSellShares -= acctPend.sellShares;
            }
            tn2.updateProtoFee(_globalInfo, true, false, assetId, acctPend.buyFees);
            tn2.updateProtoFee(_globalInfo, true, false, 1, acctPend.celrFees);
        } else {
            if (acctPend.buyAmount > 0) {
                tn2.adjustAccountIdleAssetEntries(_accountInfo, assetId);
                _accountInfo.idleAssets[assetId] += acctPend.buyAmount;
                stPend.unsettledBuyAmount -= acctPend.buyAmount;
            }
            if (acctPend.sellShares > 0) {
                _adjustAccountShareEntries(_accountInfo, stId);
                _accountInfo.shares[stId] += acctPend.sellShares;
                stPend.unsettledSellShares -= acctPend.sellShares;
            }
            _accountInfo.idleAssets[assetId] += acctPend.buyFees;
            _accountInfo.idleAssets[1] += acctPend.celrFees;
        }

        tn2.updateProtoFee(_globalInfo, false, true, assetId, acctPend.buyFees);
        tn2.updateProtoFee(_globalInfo, false, true, 1, acctPend.celrFees);

        _popHeadAccountPendingEntries(_accountInfo, stId);
        if (stPend.unsettledBuyAmount == 0 && stPend.unsettledSellShares == 0) {
            _popHeadStrategyPendingEntries(_strategyInfo);
        }

        return (_accountInfo, _strategyInfo, _globalInfo);
    }

    /**
     * @notice Apply a TransferAssetTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition (source of the transfer).
     * @param _accountInfoDest The involved destination account from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account info for both accounts, and global info after applying the disputed transition
     */
    function applyAssetTransferTransition(
        dt.TransferAssetTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.AccountInfo memory _accountInfoDest,
        dt.GlobalInfo memory _globalInfo
    )
        external
        pure
        returns (
            dt.AccountInfo memory,
            dt.AccountInfo memory,
            dt.GlobalInfo memory
        )
    {
        bytes32 txHash =
            keccak256(
                abi.encodePacked(
                    _transition.transitionType,
                    _transition.fromAccountId,
                    _transition.toAccountId,
                    _transition.assetId,
                    _transition.amount,
                    _transition.fee,
                    _transition.timestamp
                )
            );
        require(
            ECDSA.recover(ECDSA.toEthSignedMessageHash(txHash), _transition.v, _transition.r, _transition.s) ==
                _accountInfo.account,
            REQ_BAD_SIG
        );

        require(_accountInfo.accountId == _transition.fromAccountId, REQ_BAD_ACCT);
        require(_accountInfoDest.accountId == _transition.toAccountId, REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, REQ_BAD_TS);
        _accountInfo.timestamp = _transition.timestamp;

        uint32 assetId = _transition.assetId;
        uint256 amount = _transition.amount;
        (bool isCelr, uint256 fee) = tn2.getFeeInfo(_transition.fee, 0);
        if (isCelr) {
            tn2.adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] -= fee;
            _updateOpFee(_globalInfo, true, 1, fee);
        } else {
            amount -= fee;
            _updateOpFee(_globalInfo, true, assetId, fee);
        }

        tn2.adjustAccountIdleAssetEntries(_accountInfoDest, assetId);
        _accountInfo.idleAssets[assetId] -= amount;
        _accountInfoDest.idleAssets[assetId] += amount;

        return (_accountInfo, _accountInfoDest, _globalInfo);
    }

    /**
     * @notice Apply a TransferShareTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition (source of the transfer).
     * @param _accountInfoDest The involved destination account from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account info for both accounts, and global info after applying the disputed transition
     */
    function applyShareTransferTransition(
        dt.TransferShareTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.AccountInfo memory _accountInfoDest,
        dt.GlobalInfo memory _globalInfo
    )
        external
        pure
        returns (
            dt.AccountInfo memory,
            dt.AccountInfo memory,
            dt.GlobalInfo memory
        )
    {
        bytes32 txHash =
            keccak256(
                abi.encodePacked(
                    _transition.transitionType,
                    _transition.fromAccountId,
                    _transition.toAccountId,
                    _transition.strategyId,
                    _transition.shares,
                    _transition.fee,
                    _transition.timestamp
                )
            );
        require(
            ECDSA.recover(ECDSA.toEthSignedMessageHash(txHash), _transition.v, _transition.r, _transition.s) ==
                _accountInfo.account,
            REQ_BAD_SIG
        );

        require(_accountInfo.accountId == _transition.fromAccountId, REQ_BAD_ACCT);
        require(_accountInfoDest.accountId == _transition.toAccountId, REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, REQ_BAD_TS);
        _accountInfo.timestamp = _transition.timestamp;

        uint32 stId = _transition.strategyId;
        uint256 shares = _transition.shares;
        (bool isCelr, uint256 fee) = tn2.getFeeInfo(_transition.fee, 0);
        if (isCelr) {
            tn2.adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] -= fee;
            _updateOpFee(_globalInfo, true, 1, fee);
        } else {
            shares -= fee;
            _updateOpFee(_globalInfo, false, stId, fee);
        }

        _adjustAccountShareEntries(_accountInfoDest, stId);
        _accountInfo.shares[stId] -= shares;
        _accountInfoDest.shares[stId] += shares;

        return (_accountInfo, _accountInfoDest, _globalInfo);
    }

    /**
     * @notice Apply a TransferOperatorFeeTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition (source of the transfer).
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account info and global info after applying the disputed transition
     */
    function applyTransferOperatorFeeTransition(
        dt.TransferOperatorFeeTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.GlobalInfo memory _globalInfo
    ) external pure returns (dt.AccountInfo memory, dt.GlobalInfo memory) {
        require(_accountInfo.accountId == _transition.accountId, "account id not match");

        for (uint256 i = 0; i < _globalInfo.opFees.assets.length; i++) {
            uint256 assets = _globalInfo.opFees.assets[i];
            if (assets > 0) {
                tn2.adjustAccountIdleAssetEntries(_accountInfo, uint32(i));
                _accountInfo.idleAssets[i] += assets;
                _globalInfo.opFees.assets[i] = 0;
            }
        }

        for (uint256 i = 0; i < _globalInfo.opFees.shares.length; i++) {
            uint256 shares = _globalInfo.opFees.shares[i];
            if (shares > 0) {
                _adjustAccountShareEntries(_accountInfo, uint32(i));
                _accountInfo.shares[i] += shares;
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
                            _transition.accountId,
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
            REQ_BAD_SIG
        );

        require(_accountInfo.accountId == _transition.accountId, REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, REQ_BAD_TS);
        _accountInfo.timestamp = _transition.timestamp;

        uint32 poolId = _transition.poolId;
        uint256 feeInShares;
        (bool isCelr, uint256 fee) = tn2.getFeeInfo(_transition.fee, 0);
        if (isCelr) {
            tn2.adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] -= fee;
            _updateOpFee(_globalInfo, true, 1, fee);
        } else {
            feeInShares = fee;
            _updateOpFee(_globalInfo, false, _stakingPoolInfo.strategyId, fee);
        }
        uint256 addedShares = _transition.shares - feeInShares;

        _updatePoolStates(_stakingPoolInfo, _globalInfo);

        if (addedShares > 0) {
            _adjustAccountStakedShareAndStakeEntries(_accountInfo, poolId);
            uint256 addedStake =
                _getAdjustedStake(
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
        _adjustAccountShareEntries(_accountInfo, _stakingPoolInfo.strategyId);
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
                            _transition.accountId,
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
            REQ_BAD_SIG
        );

        require(_accountInfo.accountId == _transition.accountId, REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, REQ_BAD_TS);

        _accountInfo.timestamp = _transition.timestamp;

        uint32 poolId = _transition.poolId;
        uint256 feeInShares;
        (bool isCelr, uint256 fee) = tn2.getFeeInfo(_transition.fee, 0);
        if (isCelr) {
            tn2.adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] -= fee;
            _updateOpFee(_globalInfo, true, 1, fee);
        } else {
            feeInShares = fee;
            _updateOpFee(_globalInfo, false, _stakingPoolInfo.strategyId, fee);
        }
        uint256 removedShares = _transition.shares;

        _updatePoolStates(_stakingPoolInfo, _globalInfo);

        if (removedShares > 0) {
            _adjustAccountStakedShareAndStakeEntries(_accountInfo, poolId);
            uint256 removedStake =
                _accountInfo.stakes[poolId] -
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
            uint256 accumulatedReward =
                (_accountInfo.stakes[poolId] * _stakingPoolInfo.accumulatedRewardPerUnit[rewardTokenId]) /
                    STAKING_SCALE_FACTOR;
            uint256 pendingReward = (accumulatedReward - _accountInfo.rewardDebts[poolId][rewardTokenId]);
            _accountInfo.rewardDebts[poolId][rewardTokenId] = accumulatedReward;
            _accountInfo.idleAssets[_stakingPoolInfo.rewardAssetIds[rewardTokenId]] += pendingReward;
        }
        _adjustAccountShareEntries(_accountInfo, _stakingPoolInfo.strategyId);
        _accountInfo.shares[_stakingPoolInfo.strategyId] += _transition.shares - feeInShares;

        return (_accountInfo, _stakingPoolInfo, _globalInfo);
    }

    /**
     * @notice Apply an UpdatePoolInfoTransition.
     *
     * @param _transition The disputed transition.
     * @param _stakingPoolInfo The involved staking pool from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new staking pool info after applying the disputed transition
     */
    function applyUpdatePoolInfoTransition(
        dt.UpdatePoolInfoTransition memory _transition,
        dt.StakingPoolInfo memory _stakingPoolInfo,
        dt.GlobalInfo memory _globalInfo
    ) external pure returns (dt.StakingPoolInfo memory) {
        _updatePoolStates(_stakingPoolInfo, _globalInfo);

        _stakingPoolInfo.strategyId = _transition.strategyId;
        _stakingPoolInfo.rewardAssetIds = _transition.rewardAssetIds;
        _stakingPoolInfo.rewardPerEpoch = _transition.rewardPerEpoch;
        _stakingPoolInfo.stakeAdjustmentFactor = _transition.stakeAdjustmentFactor;
        return _stakingPoolInfo;
    }

    /*********************
     * Private Functions *
     *********************/

    function _updatePoolStates(dt.StakingPoolInfo memory _stakingPoolInfo, dt.GlobalInfo memory _globalInfo)
        private
        pure
    {
        uint256 totalStakes = _stakingPoolInfo.totalStakes;
        if (totalStakes == 0) {
            // Start the pool
            _stakingPoolInfo.lastRewardEpoch = _globalInfo.currEpoch;
            return;
        }
        uint256 numEpochs = _globalInfo.currEpoch - _stakingPoolInfo.lastRewardEpoch;
        for (uint32 rewardTokenId = 0; rewardTokenId < _stakingPoolInfo.rewardPerEpoch.length; rewardTokenId++) {
            uint256 pendingReward = numEpochs * _stakingPoolInfo.rewardPerEpoch[rewardTokenId];
            _stakingPoolInfo.accumulatedRewardPerUnit[rewardTokenId] += ((pendingReward * STAKING_SCALE_FACTOR) /
                totalStakes);
        }
        _stakingPoolInfo.lastRewardEpoch = _globalInfo.currEpoch;
    }

    /**
     * Helper to expand the account array of shares if needed.
     */
    function _adjustAccountShareEntries(dt.AccountInfo memory _accountInfo, uint32 stId) private pure {
        uint32 n = uint32(_accountInfo.shares.length);
        if (n <= stId) {
            uint256[] memory arr = new uint256[](stId + 1);
            for (uint32 i = 0; i < n; i++) {
                arr[i] = _accountInfo.shares[i];
            }
            for (uint32 i = n; i <= stId; i++) {
                arr[i] = 0;
            }
            _accountInfo.shares = arr;
        }
    }

    /**
     * Helper to expand and initialize the 2D array of account pending entries per strategy and aggregate IDs.
     */
    function _adjustAccountPendingEntries(
        dt.AccountInfo memory _accountInfo,
        uint32 stId,
        uint64 aggrId
    ) private pure {
        uint32 n = uint32(_accountInfo.pending.length);
        if (n <= stId) {
            dt.PendingAccountInfo[][] memory pends = new dt.PendingAccountInfo[][](stId + 1);
            for (uint32 i = 0; i < n; i++) {
                pends[i] = _accountInfo.pending[i];
            }
            for (uint32 i = n; i < stId; i++) {
                pends[i] = new dt.PendingAccountInfo[](0);
            }
            pends[stId] = new dt.PendingAccountInfo[](1);
            pends[stId][0].aggregateId = aggrId;
            _accountInfo.pending = pends;
        } else {
            uint32 npend = uint32(_accountInfo.pending[stId].length);
            if (npend == 0 || _accountInfo.pending[stId][npend - 1].aggregateId != aggrId) {
                dt.PendingAccountInfo[] memory pends = new dt.PendingAccountInfo[](npend + 1);
                for (uint32 i = 0; i < npend; i++) {
                    pends[i] = _accountInfo.pending[stId][i];
                }
                pends[npend].aggregateId = aggrId;
                _accountInfo.pending[stId] = pends;
            }
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
        } else {
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
    }

    /**
     * Helper to expand the chosen operator fee array (if needed) and add a given fee.
     * If "_assets" is true, use the assets fee array, otherwise use the shares fee array.
     */
    function _updateOpFee(
        dt.GlobalInfo memory _globalInfo,
        bool _assets,
        uint32 _idx,
        uint256 _fee
    ) private pure {
        if (_assets) {
            _globalInfo.opFees.assets = tn2.adjustUint256Array(_globalInfo.opFees.assets, _idx);
            _globalInfo.opFees.assets[_idx] += _fee;
        } else {
            _globalInfo.opFees.shares = tn2.adjustUint256Array(_globalInfo.opFees.shares, _idx);
            _globalInfo.opFees.shares[_idx] += _fee;
        }
    }

    /**
     * Helper to pop the head from the 2D array of account pending entries for a strategy.
     */
    function _popHeadAccountPendingEntries(dt.AccountInfo memory _accountInfo, uint32 stId) private pure {
        if (_accountInfo.pending.length <= uint256(stId)) {
            return;
        }

        uint256 n = _accountInfo.pending[stId].length;
        if (n == 0) {
            return;
        }

        dt.PendingAccountInfo[] memory arr = new dt.PendingAccountInfo[](n - 1); // zero is ok for empty array
        for (uint256 i = 1; i < n; i++) {
            arr[i - 1] = _accountInfo.pending[stId][i];
        }
        _accountInfo.pending[stId] = arr;
    }

    /**
     * Helper to pop the head from the strategy pending entries.
     */
    function _popHeadStrategyPendingEntries(dt.StrategyInfo memory _strategyInfo) private pure {
        uint256 n = _strategyInfo.pending.length;
        if (n == 0) {
            return;
        }

        dt.PendingStrategyInfo[] memory arr = new dt.PendingStrategyInfo[](n - 1); // zero is ok for empty array
        for (uint256 i = 1; i < n; i++) {
            arr[i - 1] = _strategyInfo.pending[i];
        }
        _strategyInfo.pending = arr;
    }

    /**
     * @notice Calculates the adjusted stake from staked shares.
     * @param _stakedShares The staked shares
     * @param _adjustmentFactor The adjustment factor, a value from (0, 1) * STAKING_SCALE_FACTOR
     */
    function _getAdjustedStake(uint256 _stakedShares, uint256 _adjustmentFactor) private pure returns (uint256) {
        return
            ((1 * STAKING_SCALE_FACTOR - _adjustmentFactor) *
                _stakedShares +
                _sqrt(STAKING_SCALE_FACTOR**2 * _adjustmentFactor * _stakedShares)) / STAKING_SCALE_FACTOR;
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
