// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/* Internal Imports */
import {DataTypes as dt} from "./libraries/DataTypes.sol";
import {Transitions as tn} from "./libraries/Transitions.sol";
import {Transitions2 as tn2} from "./libraries/Transitions2.sol";
import "./TransitionEvaluator2.sol";
import "./Registry.sol";

contract TransitionEvaluator {
    // require() error messages
    string constant REQ_ZERO_ACCT = "need 0 accounts";
    string constant REQ_ONE_ACCT = "need 1 account";
    string constant REQ_TWO_ACCT = "need 2 accounts";
    string constant REQ_ACCT_NOT_EMPTY = "account not empty";
    string constant REQ_BAD_ACCT = "wrong account";
    string constant REQ_BAD_SIG = "invalid signature";
    string constant REQ_BAD_TS = "old timestamp";
    string constant REQ_NO_PEND = "no pending info";
    string constant REQ_BAD_AMOUNT = "wrong amount";
    string constant REQ_BAD_SHARES = "wrong shares";
    string constant REQ_BAD_AGGR = "wrong aggregate ID";

    TransitionEvaluator2 transitionEvaluator2;

    // Transition evaluation is split across 2 contracts, this one is the main entry point.
    // In turn, it needs to access the 2nd contract to evaluate the other transitions.
    constructor(TransitionEvaluator2 _transitionEvaluator2) {
        transitionEvaluator2 = _transitionEvaluator2;
    }

    /**********************
     * External Functions *
     **********************/

    /**
     * @notice Evaluate a transition.
     * @dev Note: most transitions involve one account; the transfer transitions involve two (src, dest).
     * @dev Always returns 4 hashes: accountHash (src), destAccountHash, strategyHash, globalInfoHash
     *
     * @param _transition The disputed transition.
     * @param _infos The involved infos at the start of the disputed transition.
     * @param _registry The address of the Registry contract.
     * @return hashes of the accounts, strategy, staking pool and global info after applying the disputed transition.
     */
    function evaluateTransition(
        bytes calldata _transition,
        dt.EvaluateInfos calldata _infos,
        Registry _registry
    ) external view returns (bytes32[5] memory) {
        // Extract the transition type
        uint8 transitionType = tn.extractTransitionType(_transition);
        bytes32[5] memory outputs;
        dt.EvaluateInfos memory updatedInfos;
        updatedInfos.accountInfos = new dt.AccountInfo[](2);

        // Apply the transition and record the resulting storage slots
        if (transitionType == tn.TN_TYPE_DEPOSIT) {
            require(_infos.accountInfos.length == 1, REQ_ONE_ACCT);
            dt.DepositTransition memory deposit = tn.decodePackedDepositTransition(_transition);
            updatedInfos.accountInfos[0] = _applyDepositTransition(deposit, _infos.accountInfos[0]);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
        } else if (transitionType == tn.TN_TYPE_WITHDRAW) {
            require(_infos.accountInfos.length == 1, REQ_ONE_ACCT);
            dt.WithdrawTransition memory withdraw = tn.decodePackedWithdrawTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.globalInfo) = _applyWithdrawTransition(
                withdraw,
                _infos.accountInfos[0],
                _infos.globalInfo
            );
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_BUY) {
            require(_infos.accountInfos.length == 1, REQ_ONE_ACCT);
            dt.BuyTransition memory buy = tn2.decodePackedBuyTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.strategyInfo, updatedInfos.globalInfo) = transitionEvaluator2
                .applyBuyTransition(buy, _infos.accountInfos[0], _infos.strategyInfo, _infos.globalInfo, _registry);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_SELL) {
            require(_infos.accountInfos.length == 1, REQ_ONE_ACCT);
            dt.SellTransition memory sell = tn2.decodePackedSellTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.strategyInfo, updatedInfos.globalInfo) = transitionEvaluator2
                .applySellTransition(sell, _infos.accountInfos[0], _infos.strategyInfo, _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_XFER_ASSET) {
            require(_infos.accountInfos.length == 2, REQ_TWO_ACCT);
            dt.TransferAssetTransition memory xfer = tn2.decodePackedTransferAssetTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.accountInfos[1], updatedInfos.globalInfo) = transitionEvaluator2
                .applyAssetTransferTransition(xfer, _infos.accountInfos[0], _infos.accountInfos[1], _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[1] = getAccountInfoHash(updatedInfos.accountInfos[1]);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_XFER_SHARE) {
            require(_infos.accountInfos.length == 2, REQ_TWO_ACCT);
            dt.TransferShareTransition memory xfer = tn2.decodePackedTransferShareTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.accountInfos[1], updatedInfos.globalInfo) = transitionEvaluator2
                .applyShareTransferTransition(xfer, _infos.accountInfos[0], _infos.accountInfos[1], _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[1] = getAccountInfoHash(updatedInfos.accountInfos[1]);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_AGGREGATE_ORDER) {
            require(_infos.accountInfos.length == 0, REQ_ZERO_ACCT);
            dt.AggregateOrdersTransition memory aggr = tn.decodePackedAggregateOrdersTransition(_transition);
            updatedInfos.strategyInfo = _applyAggregateOrdersTransition(aggr, _infos.strategyInfo);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
        } else if (transitionType == tn.TN_TYPE_EXEC_RESULT) {
            require(_infos.accountInfos.length == 0, REQ_ZERO_ACCT);
            dt.ExecutionResultTransition memory res = tn.decodePackedExecutionResultTransition(_transition);
            updatedInfos.strategyInfo = _applyExecutionResultTransition(res, _infos.strategyInfo);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
        } else if (transitionType == tn.TN_TYPE_SETTLE) {
            require(_infos.accountInfos.length == 1, REQ_ONE_ACCT);
            dt.SettlementTransition memory settle = tn2.decodePackedSettlementTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.strategyInfo, updatedInfos.globalInfo) = transitionEvaluator2
                .applySettlementTransition(settle, _infos.accountInfos[0], _infos.strategyInfo, _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_STAKE) {
            require(_infos.accountInfos.length == 1, REQ_ONE_ACCT);
            dt.StakeTransition memory stake = tn2.decodePackedStakeTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.stakingPoolInfo, updatedInfos.globalInfo) = transitionEvaluator2
                .applyStakeTransition(stake, _infos.accountInfos[0], _infos.stakingPoolInfo, _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[3] = getStakingPoolInfoHash(updatedInfos.stakingPoolInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_UNSTAKE) {
            require(_infos.accountInfos.length == 1, REQ_ONE_ACCT);
            dt.UnstakeTransition memory unstake = tn2.decodePackedUnstakeTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.stakingPoolInfo, updatedInfos.globalInfo) = transitionEvaluator2
                .applyUnstakeTransition(unstake, _infos.accountInfos[0], _infos.stakingPoolInfo, _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[3] = getStakingPoolInfoHash(updatedInfos.stakingPoolInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_UPDATE_POOL_INFO) {
            require(_infos.accountInfos.length == 0, REQ_ZERO_ACCT);
            dt.UpdatePoolInfoTransition memory updatePoolInfo = tn2.decodeUpdatePoolInfoTransition(_transition);
            updatedInfos.stakingPoolInfo = transitionEvaluator2.applyUpdatePoolInfoTransition(
                updatePoolInfo,
                _infos.stakingPoolInfo,
                _infos.globalInfo
            );
            outputs[3] = getStakingPoolInfoHash(updatedInfos.stakingPoolInfo);
        } else if (transitionType == tn.TN_TYPE_WITHDRAW_PROTO_FEE) {
            require(_infos.accountInfos.length == 0, REQ_ZERO_ACCT);
            dt.WithdrawProtocolFeeTransition memory wpf = tn.decodeWithdrawProtocolFeeTransition(_transition);
            updatedInfos.globalInfo = _applyWithdrawProtocolFeeTransition(wpf, _infos.globalInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_XFER_OP_FEE) {
            require(_infos.accountInfos.length == 1, REQ_ONE_ACCT);
            dt.TransferOperatorFeeTransition memory tof = tn2.decodeTransferOperatorFeeTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.globalInfo) = transitionEvaluator2
                .applyTransferOperatorFeeTransition(tof, _infos.accountInfos[0], _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else {
            revert("Transition type not recognized");
        }
        return outputs;
    }

    /**
     * @notice Return the (stateRoot, accountId, accountIdDest, strategyId, stakingPoolId) for this transition.
     * @dev Note: most transitions involve one account; the transfer transitions involve a 2nd account (dest).
     */
    function getTransitionStateRootAndAccessIds(bytes calldata _rawTransition)
        external
        pure
        returns (
            bytes32,
            uint32,
            uint32,
            uint32,
            uint32
        )
    {
        // Initialize memory rawTransition
        bytes memory rawTransition = _rawTransition;
        // Initialize stateRoot and account and strategy IDs.
        bytes32 stateRoot;
        uint32 accountId;
        uint32 accountIdDest;
        uint32 strategyId;
        uint32 stakingPoolId;
        uint8 transitionType = tn.extractTransitionType(rawTransition);
        if (transitionType == tn.TN_TYPE_DEPOSIT) {
            dt.DepositTransition memory transition = tn.decodePackedDepositTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
        } else if (transitionType == tn.TN_TYPE_WITHDRAW) {
            dt.WithdrawTransition memory transition = tn.decodePackedWithdrawTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
        } else if (transitionType == tn.TN_TYPE_BUY) {
            dt.BuyTransition memory transition = tn2.decodePackedBuyTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
            strategyId = transition.strategyId;
        } else if (transitionType == tn.TN_TYPE_SELL) {
            dt.SellTransition memory transition = tn2.decodePackedSellTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
            strategyId = transition.strategyId;
        } else if (transitionType == tn.TN_TYPE_XFER_ASSET) {
            dt.TransferAssetTransition memory transition = tn2.decodePackedTransferAssetTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.fromAccountId;
            accountIdDest = transition.toAccountId;
        } else if (transitionType == tn.TN_TYPE_XFER_SHARE) {
            dt.TransferShareTransition memory transition = tn2.decodePackedTransferShareTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.fromAccountId;
            accountIdDest = transition.toAccountId;
        } else if (transitionType == tn.TN_TYPE_AGGREGATE_ORDER) {
            dt.AggregateOrdersTransition memory transition = tn.decodePackedAggregateOrdersTransition(rawTransition);
            stateRoot = transition.stateRoot;
            strategyId = transition.strategyId;
        } else if (transitionType == tn.TN_TYPE_EXEC_RESULT) {
            dt.ExecutionResultTransition memory transition = tn.decodePackedExecutionResultTransition(rawTransition);
            stateRoot = transition.stateRoot;
            strategyId = transition.strategyId;
        } else if (transitionType == tn.TN_TYPE_SETTLE) {
            dt.SettlementTransition memory transition = tn2.decodePackedSettlementTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
            strategyId = transition.strategyId;
        } else if (transitionType == tn.TN_TYPE_STAKE) {
            dt.StakeTransition memory transition = tn2.decodePackedStakeTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
            stakingPoolId = transition.poolId;
        } else if (transitionType == tn.TN_TYPE_UNSTAKE) {
            dt.UnstakeTransition memory transition = tn2.decodePackedUnstakeTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
            stakingPoolId = transition.poolId;
        } else if (transitionType == tn.TN_TYPE_UPDATE_POOL_INFO) {
            dt.UpdatePoolInfoTransition memory transition = tn2.decodeUpdatePoolInfoTransition(rawTransition);
            stateRoot = transition.stateRoot;
            stakingPoolId = transition.poolId;
        } else if (transitionType == tn.TN_TYPE_WITHDRAW_PROTO_FEE) {
            dt.WithdrawProtocolFeeTransition memory transition = tn.decodeWithdrawProtocolFeeTransition(rawTransition);
            stateRoot = transition.stateRoot;
        } else if (transitionType == tn.TN_TYPE_XFER_OP_FEE) {
            dt.TransferOperatorFeeTransition memory transition = tn2.decodeTransferOperatorFeeTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
        } else if (transitionType == tn.TN_TYPE_INIT) {
            dt.InitTransition memory transition = tn2.decodeInitTransition(rawTransition);
            stateRoot = transition.stateRoot;
        } else {
            revert("Transition type not recognized");
        }
        return (stateRoot, accountId, accountIdDest, strategyId, stakingPoolId);
    }

    /**
     * @notice Get the hash of the AccountInfo.
     * @param _accountInfo Account info
     */
    function getAccountInfoHash(dt.AccountInfo memory _accountInfo) public pure returns (bytes32) {
        // If it's an empty struct, map it to 32 bytes of zeros (empty value)
        if (
            _accountInfo.account == address(0) &&
            _accountInfo.accountId == 0 &&
            _accountInfo.idleAssets.length == 0 &&
            _accountInfo.shares.length == 0 &&
            _accountInfo.pending.length == 0 &&
            _accountInfo.stakedShares.length == 0 &&
            _accountInfo.stakes.length == 0 &&
            _accountInfo.rewardDebts.length == 0 &&
            _accountInfo.timestamp == 0
        ) {
            return keccak256(abi.encodePacked(uint256(0)));
        }

        // Here we don't use `abi.encode([struct])` because it's not clear
        // how to generate that encoding client-side.
        return
            keccak256(
                abi.encode(
                    _accountInfo.account,
                    _accountInfo.accountId,
                    _accountInfo.idleAssets,
                    _accountInfo.shares,
                    _accountInfo.pending,
                    _accountInfo.stakedShares,
                    _accountInfo.stakes,
                    _accountInfo.rewardDebts,
                    _accountInfo.timestamp
                )
            );
    }

    /**
     * @notice Get the hash of the StrategyInfo.
     * @param _strategyInfo Strategy info
     */
    function getStrategyInfoHash(dt.StrategyInfo memory _strategyInfo) public pure returns (bytes32) {
        // If it's an empty struct, map it to 32 bytes of zeros (empty value)
        if (
            _strategyInfo.assetId == 0 &&
            _strategyInfo.assetBalance == 0 &&
            _strategyInfo.shareSupply == 0 &&
            _strategyInfo.nextAggregateId == 0 &&
            _strategyInfo.lastExecAggregateId == 0 &&
            _strategyInfo.pending.length == 0
        ) {
            return keccak256(abi.encodePacked(uint256(0)));
        }

        // Here we don't use `abi.encode([struct])` because it's not clear
        // how to generate that encoding client-side.
        return
            keccak256(
                abi.encode(
                    _strategyInfo.assetId,
                    _strategyInfo.assetBalance,
                    _strategyInfo.shareSupply,
                    _strategyInfo.nextAggregateId,
                    _strategyInfo.lastExecAggregateId,
                    _strategyInfo.pending
                )
            );
    }

    /**
     * @notice Get the hash of the StakingPoolInfo.
     * @param _stakingPoolInfo Staking pool info
     */
    function getStakingPoolInfoHash(dt.StakingPoolInfo memory _stakingPoolInfo) public pure returns (bytes32) {
        // If it's an empty struct, map it to 32 bytes of zeros (empty value)
        if (
            _stakingPoolInfo.strategyId == 0 &&
            _stakingPoolInfo.rewardAssetIds.length == 0 &&
            _stakingPoolInfo.rewardPerEpoch.length == 0 &&
            _stakingPoolInfo.totalShares == 0 &&
            _stakingPoolInfo.totalStakes == 0 &&
            _stakingPoolInfo.accumulatedRewardPerUnit.length == 0 &&
            _stakingPoolInfo.lastRewardEpoch == 0 &&
            _stakingPoolInfo.stakeAdjustmentFactor == 0
        ) {
            return keccak256(abi.encodePacked(uint256(0)));
        }

        // Here we don't use `abi.encode([struct])` because it's not clear
        // how to generate that encoding client-side.
        return
            keccak256(
                abi.encode(
                    _stakingPoolInfo.strategyId,
                    _stakingPoolInfo.rewardAssetIds,
                    _stakingPoolInfo.rewardPerEpoch,
                    _stakingPoolInfo.totalShares,
                    _stakingPoolInfo.totalStakes,
                    _stakingPoolInfo.accumulatedRewardPerUnit,
                    _stakingPoolInfo.lastRewardEpoch,
                    _stakingPoolInfo.stakeAdjustmentFactor
                )
            );
    }

    /**
     * @notice Get the hash of the GlobalInfo.
     * @param _globalInfo Global info
     */
    function getGlobalInfoHash(dt.GlobalInfo memory _globalInfo) public pure returns (bytes32) {
        // If it's an empty struct, map it to 32 bytes of zeros (empty value)
        if (
            _globalInfo.protoFees.received.length == 0 &&
            _globalInfo.protoFees.pending.length == 0 &&
            _globalInfo.opFees.assets.length == 0 &&
            _globalInfo.opFees.shares.length == 0 &&
            _globalInfo.currEpoch == 0
        ) {
            return keccak256(abi.encodePacked(uint256(0)));
        }

        // Here we don't use `abi.encode([struct])` because it's not clear
        // how to generate that encoding client-side.
        return
            keccak256(
                abi.encode(
                    _globalInfo.protoFees.received,
                    _globalInfo.protoFees.pending,
                    _globalInfo.opFees.assets,
                    _globalInfo.opFees.shares,
                    _globalInfo.currEpoch
                )
            );
    }

    /*********************
     * Private Functions *
     *********************/

    /**
     * @notice Apply a DepositTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @return new account info after applying the disputed transition
     */
    function _applyDepositTransition(dt.DepositTransition memory _transition, dt.AccountInfo memory _accountInfo)
        private
        pure
        returns (dt.AccountInfo memory)
    {
        if (_accountInfo.account == address(0)) {
            // first time deposit of this account
            require(_accountInfo.accountId == 0, REQ_ACCT_NOT_EMPTY);
            require(_accountInfo.idleAssets.length == 0, REQ_ACCT_NOT_EMPTY);
            require(_accountInfo.shares.length == 0, REQ_ACCT_NOT_EMPTY);
            require(_accountInfo.pending.length == 0, REQ_ACCT_NOT_EMPTY);
            require(_accountInfo.timestamp == 0, REQ_ACCT_NOT_EMPTY);
            _accountInfo.account = _transition.account;
            _accountInfo.accountId = _transition.accountId;
        } else {
            require(_accountInfo.account == _transition.account, REQ_BAD_ACCT);
            require(_accountInfo.accountId == _transition.accountId, REQ_BAD_ACCT);
        }

        uint32 assetId = _transition.assetId;
        tn2.adjustAccountIdleAssetEntries(_accountInfo, assetId);
        _accountInfo.idleAssets[assetId] += _transition.amount;

        return _accountInfo;
    }

    /**
     * @notice Apply a WithdrawTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account and global info after applying the disputed transition
     */
    function _applyWithdrawTransition(
        dt.WithdrawTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.GlobalInfo memory _globalInfo
    ) private pure returns (dt.AccountInfo memory, dt.GlobalInfo memory) {
        bytes32 txHash =
            keccak256(
                abi.encodePacked(
                    _transition.transitionType,
                    _transition.account,
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

        require(_accountInfo.accountId == _transition.accountId, REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, REQ_BAD_TS);
        _accountInfo.timestamp = _transition.timestamp;

        _accountInfo.idleAssets[_transition.assetId] -= _transition.amount;
        tn2.updateProtoFee(_globalInfo, true, false, _transition.assetId, _transition.fee);

        return (_accountInfo, _globalInfo);
    }

    /**
     * @notice Apply an AggregateOrdersTransition.
     *
     * @param _transition The disputed transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @return new strategy info after applying the disputed transition
     */
    function _applyAggregateOrdersTransition(
        dt.AggregateOrdersTransition memory _transition,
        dt.StrategyInfo memory _strategyInfo
    ) private pure returns (dt.StrategyInfo memory) {
        uint256 npend = _strategyInfo.pending.length;
        require(npend > 0, REQ_NO_PEND);
        dt.PendingStrategyInfo memory psi = _strategyInfo.pending[npend - 1];
        require(_transition.buyAmount == psi.buyAmount, REQ_BAD_AMOUNT);
        require(_transition.sellShares == psi.sellShares, REQ_BAD_SHARES);

        uint256 minSharesFromBuy = (_transition.buyAmount * 1e18) / psi.maxSharePriceForBuy;
        uint256 minAmountFromSell = (_transition.sellShares * psi.minSharePriceForSell) / 1e18;
        require(_transition.minSharesFromBuy == minSharesFromBuy, REQ_BAD_SHARES);
        require(_transition.minAmountFromSell == minAmountFromSell, REQ_BAD_AMOUNT);

        _strategyInfo.nextAggregateId++;

        return _strategyInfo;
    }

    /**
     * @notice Apply a ExecutionResultTransition.
     *
     * @param _transition The disputed transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @return new strategy info after applying the disputed transition
     */
    function _applyExecutionResultTransition(
        dt.ExecutionResultTransition memory _transition,
        dt.StrategyInfo memory _strategyInfo
    ) private pure returns (dt.StrategyInfo memory) {
        uint256 idx;
        bool found = false;
        for (uint256 i = 0; i < _strategyInfo.pending.length; i++) {
            if (_strategyInfo.pending[i].aggregateId == _transition.aggregateId) {
                idx = i;
                found = true;
                break;
            }
        }
        require(found, REQ_BAD_AGGR);

        if (_transition.success) {
            _strategyInfo.pending[idx].sharesFromBuy = _transition.sharesFromBuy;
            _strategyInfo.pending[idx].amountFromSell = _transition.amountFromSell;
        }
        _strategyInfo.pending[idx].executionSucceed = _transition.success;
        _strategyInfo.pending[idx].unsettledBuyAmount = _strategyInfo.pending[idx].buyAmount;
        _strategyInfo.pending[idx].unsettledSellShares = _strategyInfo.pending[idx].sellShares;
        _strategyInfo.lastExecAggregateId = _transition.aggregateId;

        return _strategyInfo;
    }

    /**
     * @notice Apply a WithdrawProtocolFeeTransition.
     *
     * @param _transition The disputed transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new global info after applying the disputed transition
     */
    function _applyWithdrawProtocolFeeTransition(
        dt.WithdrawProtocolFeeTransition memory _transition,
        dt.GlobalInfo memory _globalInfo
    ) private pure returns (dt.GlobalInfo memory) {
        tn2.updateProtoFee(_globalInfo, false, false, _transition.assetId, _transition.amount);
        return _globalInfo;
    }
}
