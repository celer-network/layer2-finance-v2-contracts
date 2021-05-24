// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/* Internal Imports */
import {DataTypes as dt} from "./libraries/DataTypes.sol";
import {Transitions as tn} from "./libraries/Transitions.sol";
import "./libraries/ErrMsg.sol";
import "./TransitionApplier1.sol";
import "./TransitionApplier2.sol";
import "./Registry.sol";

contract TransitionEvaluator {
    TransitionApplier1 transitionApplier1;
    TransitionApplier2 transitionApplier2;

    // Transition evaluation is split across 3 contracts, this one is the main entry point.
    // In turn, it needs to access the other two contracts to evaluate the other transitions.
    constructor(TransitionApplier1 _transitionApplier1, TransitionApplier2 _transitionApplier2) {
        transitionApplier1 = _transitionApplier1;
        transitionApplier2 = _transitionApplier2;
    }

    /**********************
     * External Functions *
     **********************/

    /**
     * @notice Evaluate a transition.
     * @dev Note: most transitions involve one account; the transfer transitions involve two (src, dest).
     *
     * @param _transition The disputed transition.
     * @param _infos The involved infos at the start of the disputed transition.
     * @param _registry The address of the Registry contract.
     * @return hashes of the accounts (src and dest), strategy, staking pool and global info after applying the disputed transition.
     */
    function evaluateTransition(
        bytes calldata _transition,
        dt.EvaluateInfos calldata _infos,
        Registry _registry
    ) external view returns (bytes32[5] memory) {
        // Extract the transition type
        uint8 transitionType = tn.extractTransitionType(_transition);
        bytes32[5] memory outputs;
        outputs[4] = getGlobalInfoHash(_infos.globalInfo);
        dt.EvaluateInfos memory updatedInfos;
        updatedInfos.accountInfos = new dt.AccountInfo[](2);

        // Apply the transition and record the resulting storage slots
        if (transitionType == tn.TN_TYPE_DEPOSIT) {
            require(_infos.accountInfos.length == 1, ErrMsg.REQ_ONE_ACCT);
            dt.DepositTransition memory deposit = tn.decodePackedDepositTransition(_transition);
            updatedInfos.accountInfos[0] = transitionApplier1.applyDepositTransition(deposit, _infos.accountInfos[0]);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
        } else if (transitionType == tn.TN_TYPE_WITHDRAW) {
            require(_infos.accountInfos.length == 1, ErrMsg.REQ_ONE_ACCT);
            dt.WithdrawTransition memory withdraw = tn.decodePackedWithdrawTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.globalInfo) = transitionApplier1.applyWithdrawTransition(
                withdraw,
                _infos.accountInfos[0],
                _infos.globalInfo
            );
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_BUY) {
            require(_infos.accountInfos.length == 1, ErrMsg.REQ_ONE_ACCT);
            dt.BuyTransition memory buy = tn.decodePackedBuyTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.strategyInfo) = transitionApplier1.applyBuyTransition(
                buy,
                _infos.accountInfos[0],
                _infos.strategyInfo,
                _registry
            );
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
        } else if (transitionType == tn.TN_TYPE_SELL) {
            require(_infos.accountInfos.length == 1, ErrMsg.REQ_ONE_ACCT);
            dt.SellTransition memory sell = tn.decodePackedSellTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.strategyInfo) = transitionApplier1.applySellTransition(
                sell,
                _infos.accountInfos[0],
                _infos.strategyInfo
            );
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
        } else if (transitionType == tn.TN_TYPE_XFER_ASSET) {
            require(_infos.accountInfos.length == 2, ErrMsg.REQ_TWO_ACCT);
            dt.TransferAssetTransition memory xfer = tn.decodePackedTransferAssetTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.accountInfos[1], updatedInfos.globalInfo) = transitionApplier1
                .applyAssetTransferTransition(xfer, _infos.accountInfos[0], _infos.accountInfos[1], _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[1] = getAccountInfoHash(updatedInfos.accountInfos[1]);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_XFER_SHARE) {
            require(_infos.accountInfos.length == 2, ErrMsg.REQ_TWO_ACCT);
            dt.TransferShareTransition memory xfer = tn.decodePackedTransferShareTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.accountInfos[1], updatedInfos.globalInfo) = transitionApplier1
                .applyShareTransferTransition(xfer, _infos.accountInfos[0], _infos.accountInfos[1], _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[1] = getAccountInfoHash(updatedInfos.accountInfos[1]);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_AGGREGATE_ORDER) {
            require(_infos.accountInfos.length == 0, ErrMsg.REQ_ZERO_ACCT);
            dt.AggregateOrdersTransition memory aggr = tn.decodePackedAggregateOrdersTransition(_transition);
            updatedInfos.strategyInfo = transitionApplier2.applyAggregateOrdersTransition(aggr, _infos.strategyInfo);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
        } else if (transitionType == tn.TN_TYPE_EXEC_RESULT) {
            require(_infos.accountInfos.length == 0, ErrMsg.REQ_ZERO_ACCT);
            dt.ExecutionResultTransition memory res = tn.decodePackedExecutionResultTransition(_transition);
            (updatedInfos.strategyInfo, updatedInfos.globalInfo) = transitionApplier2.applyExecutionResultTransition(
                res,
                _infos.strategyInfo,
                _infos.globalInfo
            );
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_SETTLE) {
            require(_infos.accountInfos.length == 1, ErrMsg.REQ_ONE_ACCT);
            dt.SettlementTransition memory settle = tn.decodePackedSettlementTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.strategyInfo, updatedInfos.globalInfo) = transitionApplier1
                .applySettlementTransition(settle, _infos.accountInfos[0], _infos.strategyInfo, _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_STAKE) {
            require(_infos.accountInfos.length == 1, ErrMsg.REQ_ONE_ACCT);
            dt.StakeTransition memory stake = tn.decodePackedStakeTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.stakingPoolInfo, updatedInfos.globalInfo) = transitionApplier2
                .applyStakeTransition(stake, _infos.accountInfos[0], _infos.stakingPoolInfo, _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[3] = getStakingPoolInfoHash(updatedInfos.stakingPoolInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_UNSTAKE) {
            require(_infos.accountInfos.length == 1, ErrMsg.REQ_ONE_ACCT);
            dt.UnstakeTransition memory unstake = tn.decodePackedUnstakeTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.stakingPoolInfo, updatedInfos.globalInfo) = transitionApplier2
                .applyUnstakeTransition(unstake, _infos.accountInfos[0], _infos.stakingPoolInfo, _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[3] = getStakingPoolInfoHash(updatedInfos.stakingPoolInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_UPDATE_POOL_INFO) {
            require(_infos.accountInfos.length == 0, ErrMsg.REQ_ZERO_ACCT);
            dt.UpdatePoolInfoTransition memory updatePoolInfo = tn.decodeUpdatePoolInfoTransition(_transition);
            updatedInfos.stakingPoolInfo = transitionApplier2.applyUpdatePoolInfoTransition(
                updatePoolInfo,
                _infos.stakingPoolInfo,
                _infos.globalInfo
            );
            outputs[3] = getStakingPoolInfoHash(updatedInfos.stakingPoolInfo);
        } else if (transitionType == tn.TN_TYPE_DEPOSIT_REWARD) {
            require(_infos.accountInfos.length == 0, ErrMsg.REQ_ZERO_ACCT);
            dt.DepositRewardTransition memory dr = tn.decodeDepositRewardTransition(_transition);
            updatedInfos.globalInfo = transitionApplier2.applyDepositRewardTransition(dr, _infos.globalInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_WITHDRAW_PROTO_FEE) {
            require(_infos.accountInfos.length == 0, ErrMsg.REQ_ZERO_ACCT);
            dt.WithdrawProtocolFeeTransition memory wpf = tn.decodeWithdrawProtocolFeeTransition(_transition);
            updatedInfos.globalInfo = transitionApplier2.applyWithdrawProtocolFeeTransition(wpf, _infos.globalInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_XFER_OP_FEE) {
            require(_infos.accountInfos.length == 1, ErrMsg.REQ_ONE_ACCT);
            dt.TransferOperatorFeeTransition memory tof = tn.decodeTransferOperatorFeeTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.globalInfo) = transitionApplier2
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
            dt.BuyTransition memory transition = tn.decodePackedBuyTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
            strategyId = transition.strategyId;
        } else if (transitionType == tn.TN_TYPE_SELL) {
            dt.SellTransition memory transition = tn.decodePackedSellTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
            strategyId = transition.strategyId;
        } else if (transitionType == tn.TN_TYPE_XFER_ASSET) {
            dt.TransferAssetTransition memory transition = tn.decodePackedTransferAssetTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.fromAccountId;
            accountIdDest = transition.toAccountId;
        } else if (transitionType == tn.TN_TYPE_XFER_SHARE) {
            dt.TransferShareTransition memory transition = tn.decodePackedTransferShareTransition(rawTransition);
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
            dt.SettlementTransition memory transition = tn.decodePackedSettlementTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
            strategyId = transition.strategyId;
        } else if (transitionType == tn.TN_TYPE_STAKE) {
            dt.StakeTransition memory transition = tn.decodePackedStakeTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
            stakingPoolId = transition.poolId;
        } else if (transitionType == tn.TN_TYPE_UNSTAKE) {
            dt.UnstakeTransition memory transition = tn.decodePackedUnstakeTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
            stakingPoolId = transition.poolId;
        } else if (transitionType == tn.TN_TYPE_UPDATE_POOL_INFO) {
            dt.UpdatePoolInfoTransition memory transition = tn.decodeUpdatePoolInfoTransition(rawTransition);
            stateRoot = transition.stateRoot;
            stakingPoolId = transition.poolId;
        } else if (transitionType == tn.TN_TYPE_DEPOSIT_REWARD) {
            dt.DepositRewardTransition memory transition = tn.decodeDepositRewardTransition(rawTransition);
            stateRoot = transition.stateRoot;
        } else if (transitionType == tn.TN_TYPE_WITHDRAW_PROTO_FEE) {
            dt.WithdrawProtocolFeeTransition memory transition = tn.decodeWithdrawProtocolFeeTransition(rawTransition);
            stateRoot = transition.stateRoot;
        } else if (transitionType == tn.TN_TYPE_XFER_OP_FEE) {
            dt.TransferOperatorFeeTransition memory transition = tn.decodeTransferOperatorFeeTransition(rawTransition);
            stateRoot = transition.stateRoot;
            accountId = transition.accountId;
        } else if (transitionType == tn.TN_TYPE_INIT) {
            dt.InitTransition memory transition = tn.decodeInitTransition(rawTransition);
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
            _globalInfo.protoFees.length == 0 &&
            _globalInfo.opFees.assets.length == 0 &&
            _globalInfo.opFees.shares.length == 0 &&
            _globalInfo.currEpoch == 0 &&
            _globalInfo.rewards.length == 0
        ) {
            return keccak256(abi.encodePacked(uint256(0)));
        }

        // Here we don't use `abi.encode([struct])` because it's not clear
        // how to generate that encoding client-side.
        return
            keccak256(
                abi.encode(
                    _globalInfo.protoFees,
                    _globalInfo.opFees.assets,
                    _globalInfo.opFees.shares,
                    _globalInfo.currEpoch,
                    _globalInfo.rewards
                )
            );
    }
}
