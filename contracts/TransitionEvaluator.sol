// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/* Internal Imports */
import {DataTypes as dt} from "./libraries/DataTypes.sol";
import {Transitions as tn} from "./libraries/Transitions.sol";
import "./Registry.sol";
import "./strategies/interfaces/IStrategy.sol";

contract TransitionEvaluator {
    using SafeMath for uint256;

    uint128 public constant UINT128_MAX = 2**128 - 1;
    uint128 public constant UINT128_HIBIT = 2**127;

    uint256 public constant STAKING_SCALE_FACTOR = 1e12;

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

        // Apply the transition and record the resulting storage slots
        if (transitionType == tn.TN_TYPE_DEPOSIT) {
            require(_infos.accountInfos.length == 1, "One account is needed for a deposit transition");
            dt.DepositTransition memory deposit = tn.decodePackedDepositTransition(_transition);
            updatedInfos.accountInfos[0] = _applyDepositTransition(deposit, _infos.accountInfos[0]);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
        } else if (transitionType == tn.TN_TYPE_WITHDRAW) {
            require(_infos.accountInfos.length == 1, "One account is needed for a withdraw transition");
            dt.WithdrawTransition memory withdraw = tn.decodePackedWithdrawTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.globalInfo) = _applyWithdrawTransition(
                withdraw,
                _infos.accountInfos[0],
                _infos.globalInfo
            );
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_BUY) {
            require(_infos.accountInfos.length == 1, "One account is needed for a buy transition");
            dt.BuyTransition memory buy = tn.decodePackedBuyTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.strategyInfo, updatedInfos.globalInfo) = _applyBuyTransition(
                buy,
                _infos.accountInfos[0],
                _infos.strategyInfo,
                _infos.globalInfo,
                _registry
            );
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_SELL) {
            require(_infos.accountInfos.length == 1, "One account is needed for a sell transition");
            dt.SellTransition memory sell = tn.decodePackedSellTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.strategyInfo, updatedInfos.globalInfo) = _applySellTransition(
                sell,
                _infos.accountInfos[0],
                _infos.strategyInfo,
                _infos.globalInfo
            );
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_XFER_ASSET) {
            require(_infos.accountInfos.length == 2, "Two accounts are needed for an asset transfer transition");
            dt.TransferAssetTransition memory xfer = tn.decodePackedTransferAssetTransition(_transition);
            (
                updatedInfos.accountInfos[0],
                updatedInfos.accountInfos[1],
                updatedInfos.globalInfo
            ) = _applyAssetTransferTransition(xfer, _infos.accountInfos[0], _infos.accountInfos[1], _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[1] = getAccountInfoHash(updatedInfos.accountInfos[1]);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_XFER_SHARE) {
            require(_infos.accountInfos.length == 2, "Two accounts are needed for a share transfer transition");
            dt.TransferShareTransition memory xfer = tn.decodePackedTransferShareTransition(_transition);
            (
                updatedInfos.accountInfos[0],
                updatedInfos.accountInfos[1],
                updatedInfos.globalInfo
            ) = _applyShareTransferTransition(xfer, _infos.accountInfos[0], _infos.accountInfos[1], _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[1] = getAccountInfoHash(updatedInfos.accountInfos[1]);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_AGGREGATE_ORDER) {
            require(_infos.accountInfos.length == 0, "No accounts are needed for an aggregate order transition");
            dt.AggregateOrdersTransition memory aggr = tn.decodePackedAggregateOrdersTransition(_transition);
            updatedInfos.strategyInfo = _applyAggregateOrdersTransition(aggr, _infos.strategyInfo);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
        } else if (transitionType == tn.TN_TYPE_EXEC_RESULT) {
            require(_infos.accountInfos.length == 0, "No accounts are needed for an execution result transition");
            dt.ExecutionResultTransition memory res = tn.decodePackedExecutionResultTransition(_transition);
            updatedInfos.strategyInfo = _applyExecutionResultTransition(res, _infos.strategyInfo);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
        } else if (transitionType == tn.TN_TYPE_SETTLE) {
            require(_infos.accountInfos.length == 1, "One account is needed for a settlement transition");
            dt.SettlementTransition memory settle = tn.decodePackedSettlementTransition(_transition);
            (
                updatedInfos.accountInfos[0],
                updatedInfos.strategyInfo,
                updatedInfos.globalInfo
            ) = _applySettlementTransition(settle, _infos.accountInfos[0], _infos.strategyInfo, _infos.globalInfo);
            outputs[0] = getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[2] = getStrategyInfoHash(updatedInfos.strategyInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_STAKE) {
            require(_infos.accountInfos.length == 1, "One account is needed for a stake transition");
            dt.StakeTransition memory stake = tn.decodePackedStakeTransition(_transition);
            (
                updatedInfos.accountInfos[0],
                updatedInfos.stakingPoolInfo,
                updatedInfos.globalInfo
            ) = _applyStakeTransition(stake, _infos.accountInfos[0], _infos.stakingPoolInfo, _infos.globalInfo);
            outputs[0] = _getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[3] = _getStakingPoolInfoHash(updatedInfos.stakingPoolInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_UNSTAKE) {
            require(_infos.accountInfos.length == 1, "One account is needed for an unstake transition");
            dt.UnstakeTransition memory unstake = tn.decodePackedUnstakeTransition(_transition);
            (
                updatedInfos.accountInfos[0],
                updatedInfos.stakingPoolInfo,
                updatedInfos.globalInfo
            ) = _applyUnstakeTransition(unstake, _infos.accountInfos[0], _infos.stakingPoolInfo, _infos.globalInfo);
            outputs[0] = _getAccountInfoHash(updatedInfos.accountInfos[0]);
            outputs[3] = _getStakingPoolInfoHash(updatedInfos.stakingPoolInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_UPDATE_POOL_INFO) {
            require(_infos.accountInfos.length == 0, "No accounts are needed for a update pool info transition");
            dt.UpdatePoolInfoTransition memory updatePoolInfo = tn.decodeUpdatePoolInfoTransition(_transition);
            updatedInfos.stakingPoolInfo = _applyUpdatePoolInfoTransition(
                updatePoolInfo,
                _infos.stakingPoolInfo,
                _infos.globalInfo
            );
            outputs[3] = _getStakingPoolInfoHash(updatedInfos.stakingPoolInfo);
        } else if (transitionType == tn.TN_TYPE_WITHDRAW_PROTO_FEE) {
            require(_infos.accountInfos.length == 0, "No accounts are needed for a withdraw protocol fee transition");
            dt.WithdrawProtocolFeeTransition memory wpf = tn.decodeWithdrawProtocolFeeTransition(_transition);
            updatedInfos.globalInfo = _applyWithdrawProtocolFeeTransition(wpf, _infos.globalInfo);
            outputs[4] = getGlobalInfoHash(updatedInfos.globalInfo);
        } else if (transitionType == tn.TN_TYPE_XFER_OP_FEE) {
            require(_infos.accountInfos.length == 1, "One account is needed for a transfer operator fee transition");
            dt.TransferOperatorFeeTransition memory tof = tn.decodeTransferOperatorFeeTransition(_transition);
            (updatedInfos.accountInfos[0], updatedInfos.globalInfo) = _applyTransferOperatorFeeTransition(
                tof,
                _infos.accountInfos[0],
                _infos.globalInfo
            );
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
            require(_accountInfo.accountId == 0, "empty account id must be zero");
            require(_accountInfo.idleAssets.length == 0, "empty account idleAssets must be empty");
            require(_accountInfo.shares.length == 0, "empty account shares must be empty");
            require(_accountInfo.pending.length == 0, "empty account PendingAccountInfo must be empty");
            require(_accountInfo.timestamp == 0, "empty account timestamp must be zero");
            _accountInfo.account = _transition.account;
            _accountInfo.accountId = _transition.accountId;
        } else {
            require(_accountInfo.account == _transition.account, "account address not match");
            require(_accountInfo.accountId == _transition.accountId, "account id not match");
        }

        uint32 assetId = _transition.assetId;
        _adjustAccountIdleAssetEntries(_accountInfo, assetId);
        _accountInfo.idleAssets[assetId] = _accountInfo.idleAssets[assetId].add(_transition.amount);

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
            "Withdraw signature is invalid"
        );

        require(_accountInfo.accountId == _transition.accountId, "account id not match");
        require(_accountInfo.timestamp < _transition.timestamp, "timestamp should be monotonically increasing");
        _accountInfo.timestamp = _transition.timestamp;

        _accountInfo.idleAssets[_transition.assetId] = _accountInfo.idleAssets[_transition.assetId].sub(
            _transition.amount
        );
        _updateProtoFee(_globalInfo, true, false, _transition.assetId, _transition.fee);

        return (_accountInfo, _globalInfo);
    }

    /**
     * @notice Apply a BuyTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account, strategy info, and global info after applying the disputed transition
     */
    function _applyBuyTransition(
        dt.BuyTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StrategyInfo memory _strategyInfo,
        dt.GlobalInfo memory _globalInfo,
        Registry _registry
    )
        private
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
            "Buy signature is invalid"
        );

        require(_accountInfo.accountId == _transition.accountId, "account id not match");
        require(_accountInfo.timestamp < _transition.timestamp, "timestamp should be monotonically increasing");
        _accountInfo.timestamp = _transition.timestamp;

        if (_strategyInfo.assetId == 0) {
            // first time commit of new strategy
            require(_strategyInfo.shareSupply == 0, "empty strategy shareSupply must be zero");
            require(_strategyInfo.nextAggregateId == 0, "empty strategy nextAggregateId must be zero");
            require(_strategyInfo.lastExecAggregateId == 0, "empty strategy lastExecAggregateId must be zero");
            require(_strategyInfo.pending.length == 0, "empty strategy pending must be empty");

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
        (bool isCelr, uint256 fee) = _getFeeInfo(_transition.fee, _transition.reducedFee);
        if (isCelr) {
            _adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] = _accountInfo.idleAssets[1].sub(fee);
            _updateProtoFee(_globalInfo, true, true, 1, fee);
        } else {
            amount = amount.sub(fee);
            _adjustAccountIdleAssetEntries(_accountInfo, _strategyInfo.assetId);
            _accountInfo.idleAssets[_strategyInfo.assetId] = _accountInfo.idleAssets[_strategyInfo.assetId].sub(amount);
            _updateProtoFee(_globalInfo, true, true, _strategyInfo.assetId, fee);
        }

        _strategyInfo.pending[npend - 1].buyAmount = _strategyInfo.pending[npend - 1].buyAmount.add(amount);

        _adjustAccountPendingEntries(_accountInfo, _transition.strategyId, _strategyInfo.nextAggregateId);
        npend = _accountInfo.pending[_transition.strategyId].length;
        dt.PendingAccountInfo memory pai = _accountInfo.pending[_transition.strategyId][npend - 1];
        _accountInfo.pending[_transition.strategyId][npend - 1].buyAmount = pai.buyAmount.add(amount);
        if (isCelr) {
            _accountInfo.pending[_transition.strategyId][npend - 1].celrFees = pai.celrFees.add(fee);
        } else {
            _accountInfo.pending[_transition.strategyId][npend - 1].buyFees = pai.buyFees.add(fee);
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
    function _applySellTransition(
        dt.SellTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StrategyInfo memory _strategyInfo,
        dt.GlobalInfo memory _globalInfo
    )
        private
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
            "Sell signature is invalid"
        );

        require(_accountInfo.accountId == _transition.accountId, "account id not match");
        require(_accountInfo.timestamp < _transition.timestamp, "timestamp should be monotonically increasing");
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

        (bool isCelr, uint256 fee) = _getFeeInfo(_transition.fee, _transition.reducedFee);
        if (isCelr) {
            _adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] = _accountInfo.idleAssets[1].sub(fee);
            _updateProtoFee(_globalInfo, true, true, 1, fee);
        }

        uint32 stId = _transition.strategyId;
        _accountInfo.shares[stId] = _accountInfo.shares[stId].sub(_transition.shares);
        _strategyInfo.pending[npend - 1].sellShares = _strategyInfo.pending[npend - 1].sellShares.add(
            _transition.shares
        );

        _adjustAccountPendingEntries(_accountInfo, stId, _strategyInfo.nextAggregateId);
        npend = _accountInfo.pending[stId].length;
        dt.PendingAccountInfo memory pai = _accountInfo.pending[stId][npend - 1];
        _accountInfo.pending[stId][npend - 1].sellShares = pai.sellShares.add(_transition.shares);
        if (isCelr) {
            _accountInfo.pending[stId][npend - 1].celrFees = pai.celrFees.add(fee);
        } else {
            _accountInfo.pending[stId][npend - 1].sellFees = pai.sellFees.add(fee);
        }

        return (_accountInfo, _strategyInfo, _globalInfo);
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
        require(npend > 0, "no pending strategy info");
        dt.PendingStrategyInfo memory psi = _strategyInfo.pending[npend - 1];
        require(_transition.buyAmount == psi.buyAmount, "pending buy amount not match");
        require(_transition.sellShares == psi.sellShares, "pending sell shares not match");

        uint256 minSharesFromBuy = _transition.buyAmount.mul(1e18).div(psi.maxSharePriceForBuy);
        uint256 minAmountFromSell = _transition.sellShares.mul(psi.minSharePriceForSell).div(1e18);
        require(_transition.minSharesFromBuy == minSharesFromBuy, "minSharesFromBuy not match");
        require(_transition.minAmountFromSell == minAmountFromSell, "minAmountFromSell not match");

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
        require(found, "aggregateId not found in pending");

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
     * @notice Apply a SettlementTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account, strategy info, and global info after applying the disputed transition
     */
    function _applySettlementTransition(
        dt.SettlementTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StrategyInfo memory _strategyInfo,
        dt.GlobalInfo memory _globalInfo
    )
        private
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
        require(aggrId <= _strategyInfo.lastExecAggregateId, "aggregateId after exec");
        require(_strategyInfo.pending.length > 0, "no pending strategy info");
        require(aggrId == _strategyInfo.pending[0].aggregateId, "aggregateId not match in strategy");
        require(_accountInfo.pending.length > stId, "invalid strategyId for account");
        require(_accountInfo.pending[stId].length > 0, "no pending account info for strategyId");
        require(aggrId == _accountInfo.pending[stId][0].aggregateId, "aggregateId not match in account");

        dt.PendingStrategyInfo memory stPend = _strategyInfo.pending[0];
        dt.PendingAccountInfo memory acctPend = _accountInfo.pending[stId][0];

        if (stPend.executionSucceed) {
            if (acctPend.buyAmount > 0) {
                _adjustAccountShareEntries(_accountInfo, stId);
                uint256 shares = acctPend.buyAmount.mul(stPend.sharesFromBuy).div(stPend.buyAmount);
                _accountInfo.shares[stId] = _accountInfo.shares[stId].add(shares);
                stPend.unsettledBuyAmount = stPend.unsettledBuyAmount.sub(acctPend.buyAmount);
            }
            if (acctPend.sellShares > 0) {
                _adjustAccountIdleAssetEntries(_accountInfo, assetId);
                uint256 amount = acctPend.sellShares.mul(stPend.amountFromSell).div(stPend.sellShares);
                uint256 fee = acctPend.sellFees;
                if (amount < fee) {
                    fee = amount;
                }
                amount = amount.sub(fee);
                _updateProtoFee(_globalInfo, true, false, assetId, fee);
                _accountInfo.idleAssets[assetId] = _accountInfo.idleAssets[assetId].add(amount);
                stPend.unsettledSellShares = stPend.unsettledSellShares.sub(acctPend.sellShares);
            }
            _updateProtoFee(_globalInfo, true, false, assetId, acctPend.buyFees);
            _updateProtoFee(_globalInfo, true, false, 1, acctPend.celrFees);
        } else {
            if (acctPend.buyAmount > 0) {
                _adjustAccountIdleAssetEntries(_accountInfo, assetId);
                _accountInfo.idleAssets[assetId] = _accountInfo.idleAssets[assetId].add(acctPend.buyAmount);
                stPend.unsettledBuyAmount = stPend.unsettledBuyAmount.sub(acctPend.buyAmount);
            }
            if (acctPend.sellShares > 0) {
                _adjustAccountShareEntries(_accountInfo, stId);
                _accountInfo.shares[stId] = _accountInfo.shares[stId].add(acctPend.sellShares);
                stPend.unsettledSellShares = stPend.unsettledSellShares.sub(acctPend.sellShares);
            }
            _accountInfo.idleAssets[assetId] = _accountInfo.idleAssets[assetId].add(acctPend.buyFees);
            _accountInfo.idleAssets[1] = _accountInfo.idleAssets[1].add(acctPend.celrFees);
        }

        _updateProtoFee(_globalInfo, false, true, assetId, acctPend.buyFees);
        _updateProtoFee(_globalInfo, false, true, 1, acctPend.celrFees);

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
    function _applyAssetTransferTransition(
        dt.TransferAssetTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.AccountInfo memory _accountInfoDest,
        dt.GlobalInfo memory _globalInfo
    )
        private
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
            "Transfer assets signature is invalid"
        );

        require(_accountInfo.accountId == _transition.fromAccountId, "source account id not match");
        require(_accountInfoDest.accountId == _transition.toAccountId, "destination account id not match");
        require(_accountInfo.timestamp < _transition.timestamp, "timestamp should be monotonically increasing");
        _accountInfo.timestamp = _transition.timestamp;

        uint32 assetId = _transition.assetId;
        uint256 amount = _transition.amount;
        (bool isCelr, uint256 fee) = _getFeeInfo(_transition.fee, 0);
        if (isCelr) {
            _adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] = _accountInfo.idleAssets[1].sub(fee);
            _updateOpFee(_globalInfo, true, 1, fee);
        } else {
            amount = amount.sub(fee);
            _updateOpFee(_globalInfo, true, assetId, fee);
        }

        _adjustAccountIdleAssetEntries(_accountInfoDest, assetId);
        _accountInfo.idleAssets[assetId] = _accountInfo.idleAssets[assetId].sub(amount);
        _accountInfoDest.idleAssets[assetId] = _accountInfoDest.idleAssets[assetId].add(amount);

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
    function _applyShareTransferTransition(
        dt.TransferShareTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.AccountInfo memory _accountInfoDest,
        dt.GlobalInfo memory _globalInfo
    )
        private
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
            "Transfer shares signature is invalid"
        );

        require(_accountInfo.accountId == _transition.fromAccountId, "source account id not match");
        require(_accountInfoDest.accountId == _transition.toAccountId, "destination account id not match");
        require(_accountInfo.timestamp < _transition.timestamp, "timestamp should be monotonically increasing");
        _accountInfo.timestamp = _transition.timestamp;

        uint32 stId = _transition.strategyId;
        uint256 shares = _transition.shares;
        (bool isCelr, uint256 fee) = _getFeeInfo(_transition.fee, 0);
        if (isCelr) {
            _adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] = _accountInfo.idleAssets[1].sub(fee);
            _updateOpFee(_globalInfo, true, 1, fee);
        } else {
            shares = shares.sub(fee);
            _updateOpFee(_globalInfo, false, stId, fee);
        }

        _adjustAccountShareEntries(_accountInfoDest, stId);
        _accountInfo.shares[stId] = _accountInfo.shares[stId].sub(shares);
        _accountInfoDest.shares[stId] = _accountInfoDest.shares[stId].add(shares);

        return (_accountInfo, _accountInfoDest, _globalInfo);
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
        _updateProtoFee(_globalInfo, false, false, _transition.assetId, _transition.amount);
        return _globalInfo;
    }

    /**
     * @notice Apply a TransferOperatorFeeTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition (source of the transfer).
     * @param _globalInfo The involved global info from the previous transition.
     * @return new account info and global info after applying the disputed transition
     */
    function _applyTransferOperatorFeeTransition(
        dt.TransferOperatorFeeTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.GlobalInfo memory _globalInfo
    ) private pure returns (dt.AccountInfo memory, dt.GlobalInfo memory) {
        require(_accountInfo.accountId == _transition.accountId, "account id not match");

        for (uint256 i = 0; i < _globalInfo.opFees.assets.length; i++) {
            uint256 assets = _globalInfo.opFees.assets[i];
            if (assets > 0) {
                _adjustAccountIdleAssetEntries(_accountInfo, uint32(i));
                _accountInfo.idleAssets[i] = _accountInfo.idleAssets[i].add(assets);
                _globalInfo.opFees.assets[i] = 0;
            }
        }

        for (uint256 i = 0; i < _globalInfo.opFees.shares.length; i++) {
            uint256 shares = _globalInfo.opFees.shares[i];
            if (shares > 0) {
                _adjustAccountShareEntries(_accountInfo, uint32(i));
                _accountInfo.shares[i] = _accountInfo.shares[i].add(shares);
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
    function _applyStakeTransition(
        dt.StakeTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StakingPoolInfo memory _stakingPoolInfo,
        dt.GlobalInfo memory _globalInfo
    )
        private
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
            "Stake signature is invalid"
        );

        require(_accountInfo.accountId == _transition.accountId, "account id not match");
        require(_accountInfo.timestamp < _transition.timestamp, "timestamp should be monotonically increasing");
        _accountInfo.timestamp = _transition.timestamp;

        uint32 poolId = _transition.poolId;
        uint256 shares = _transition.shares;
        (bool isCelr, uint256 fee) = _getFeeInfo(_transition.fee, 0);
        uint256 feeInShares = fee;
        if (isCelr) {
            feeInShares = 0;
            _adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] -= fee;
            _updateOpFee(_globalInfo, true, 1, fee);
        } else {
            _updateOpFee(_globalInfo, false, _stakingPoolInfo.shareId, fee);
        }

        _updatePoolStates(_stakingPoolInfo, _globalInfo);

        if (shares > 0) {
            _adjustAccountStakedShareEntries(_accountInfo, poolId);
            _adjustAccountStakeEntries(_accountInfo, poolId);
            uint256 addedStake =
                _getAdjustedStake(_accountInfo.stakedShares[poolId] + shares, _stakingPoolInfo.stakeAdjustmentFactor) -
                    _accountInfo.stakes[poolId];
            _accountInfo.stakedShares[poolId] += shares;
            _accountInfo.stakes[poolId] += addedStake;
            _stakingPoolInfo.totalShares += shares;
            _stakingPoolInfo.totalStakes += addedStake;

            for (uint32 rewardTokenId = 0; rewardTokenId < _stakingPoolInfo.rewardPerEpoch.length; rewardTokenId++) {
                _adjustAccountRewardDebtEntries(_accountInfo, poolId, rewardTokenId);
                _accountInfo.rewardDebts[poolId][rewardTokenId] +=
                    (addedStake * _stakingPoolInfo.accumulatedRewardPerUnit[rewardTokenId]) /
                    STAKING_SCALE_FACTOR;
            }
        }
        _accountInfo.shares[_stakingPoolInfo.shareId] -= shares + feeInShares;

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
    function _applyUnstakeTransition(
        dt.UnstakeTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StakingPoolInfo memory _stakingPoolInfo,
        dt.GlobalInfo memory _globalInfo
    )
        private
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
            "Unstake signature is invalid"
        );

        require(_accountInfo.accountId == _transition.accountId, "account id not match");
        require(_accountInfo.timestamp < _transition.timestamp, "timestamp should be monotonically increasing");

        _accountInfo.timestamp = _transition.timestamp;

        uint32 poolId = _transition.poolId;
        (bool isCelr, uint256 fee) = _getFeeInfo(_transition.fee, 0);
        uint256 feeInShares = fee;
        if (isCelr) {
            feeInShares = 0;
            _adjustAccountIdleAssetEntries(_accountInfo, 1);
            _accountInfo.idleAssets[1] -= fee;
            _updateOpFee(_globalInfo, true, 1, fee);
        } else {
            _updateOpFee(_globalInfo, false, _stakingPoolInfo.shareId, fee);
        }

        _updatePoolStates(_stakingPoolInfo, _globalInfo);

        _adjustAccountStakedShareEntries(_accountInfo, poolId);
        _adjustAccountStakeEntries(_accountInfo, poolId);
        uint256 unstakedShares = _transition.shares + feeInShares;
        uint256 removedStake =
            _accountInfo.stakes[poolId] -
                _getAdjustedStake(
                    _accountInfo.stakedShares[poolId] - unstakedShares,
                    _stakingPoolInfo.stakeAdjustmentFactor
                );
        _accountInfo.stakedShares[poolId] -= unstakedShares;
        _accountInfo.stakes[poolId] -= removedStake;
        _stakingPoolInfo.totalShares -= unstakedShares;
        _stakingPoolInfo.totalStakes -= removedStake;

        for (uint32 rewardTokenId = 0; rewardTokenId < _stakingPoolInfo.rewardPerEpoch.length; rewardTokenId++) {
            _adjustAccountRewardDebtEntries(_accountInfo, poolId, rewardTokenId);
            _accountInfo.rewardDebts[poolId][rewardTokenId] -=
                (removedStake * _stakingPoolInfo.accumulatedRewardPerUnit[rewardTokenId]) /
                STAKING_SCALE_FACTOR;
            // Harvest
            uint256 accumulatedReward =
                (_accountInfo.stakes[poolId] * _stakingPoolInfo.accumulatedRewardPerUnit[rewardTokenId]) /
                    STAKING_SCALE_FACTOR;
            uint256 pendingReward = (accumulatedReward - _accountInfo.rewardDebts[poolId][rewardTokenId]);
            _accountInfo.rewardDebts[poolId][rewardTokenId] = accumulatedReward;
            _accountInfo.idleAssets[_stakingPoolInfo.rewardAssetIds[rewardTokenId]] += pendingReward;
        }

        _accountInfo.shares[_stakingPoolInfo.shareId] += _transition.shares;

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
    function _applyUpdatePoolInfoTransition(
        dt.UpdatePoolInfoTransition memory _transition,
        dt.StakingPoolInfo memory _stakingPoolInfo,
        dt.GlobalInfo memory _globalInfo
    ) private pure returns (dt.StakingPoolInfo memory) {
        _updatePoolStates(_stakingPoolInfo, _globalInfo);

        _stakingPoolInfo.shareId = _transition.shareId;
        _stakingPoolInfo.rewardAssetIds = _transition.rewardAssetIds;
        _stakingPoolInfo.rewardPerEpoch = _transition.rewardPerEpoch;
        _stakingPoolInfo.stakeAdjustmentFactor = _transition.stakeAdjustmentFactor;
        return _stakingPoolInfo;
    }

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
     * Helper to expand the account array of idle assets if needed.
     */
    function _adjustAccountIdleAssetEntries(dt.AccountInfo memory _accountInfo, uint32 assetId) private pure {
        uint32 n = uint32(_accountInfo.idleAssets.length);
        if (n <= assetId) {
            uint256[] memory arr = new uint256[](assetId + 1);
            for (uint32 i = 0; i < n; i++) {
                arr[i] = _accountInfo.idleAssets[i];
            }
            for (uint32 i = n; i <= assetId; i++) {
                arr[i] = 0;
            }
            _accountInfo.idleAssets = arr;
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
     * Helper to expand the account array of staked shares if needed.
     */
    function _adjustAccountStakedShareEntries(dt.AccountInfo memory _accountInfo, uint32 poolId) private pure {
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
    }

    /**
     * Helper to expand the account array of stakes if needed.
     */
    function _adjustAccountStakeEntries(dt.AccountInfo memory _accountInfo, uint32 poolId) private pure {
        uint32 n = uint32(_accountInfo.stakes.length);
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
     * Helper to expand the chosen protocol fee array (if needed) and add or subtract a given fee.
     * If "_pending" is true, use the pending fee array, otherwise use the received fee array.
     */
    function _updateProtoFee(
        dt.GlobalInfo memory _globalInfo,
        bool _add,
        bool _pending,
        uint32 _assetId,
        uint256 _fee
    ) private pure {
        if (_pending) {
            _globalInfo.protoFees.pending = _adjustUint256Array(_globalInfo.protoFees.pending, _assetId);
            uint256 val = _globalInfo.protoFees.pending[_assetId];
            if (_add) {
                _globalInfo.protoFees.pending[_assetId] = val.add(_fee);
            } else {
                _globalInfo.protoFees.pending[_assetId] = val.sub(_fee);
            }
        } else {
            _globalInfo.protoFees.received = _adjustUint256Array(_globalInfo.protoFees.received, _assetId);
            uint256 val = _globalInfo.protoFees.received[_assetId];
            if (_add) {
                _globalInfo.protoFees.received[_assetId] = val.add(_fee);
            } else {
                _globalInfo.protoFees.received[_assetId] = val.sub(_fee);
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
            _globalInfo.opFees.assets = _adjustUint256Array(_globalInfo.opFees.assets, _idx);
            _globalInfo.opFees.assets[_idx] = _globalInfo.opFees.assets[_idx].add(_fee);
        } else {
            _globalInfo.opFees.shares = _adjustUint256Array(_globalInfo.opFees.shares, _idx);
            _globalInfo.opFees.shares[_idx] = _globalInfo.opFees.shares[_idx].add(_fee);
        }
    }

    /**
     * Helper to expand an array of uint256, e.g. the various fee arrays in globalInfo.
     * Takes the array and the needed index and returns the unchanged array or a new expanded one.
     */
    function _adjustUint256Array(uint256[] memory _array, uint32 _idx) private pure returns (uint256[] memory) {
        uint32 n = uint32(_array.length);
        if (_idx < n) {
            return _array;
        }

        uint256[] memory newArray = new uint256[](_idx + 1);
        for (uint32 i = 0; i < n; i++) {
            newArray[i] = _array[i];
        }
        for (uint32 i = n; i <= _idx; i++) {
            newArray[i] = 0;
        }

        return newArray;
    }

    /**
     * Helper to get the fee type and handle any fee reduction.
     * Returns (isCelr, fee).
     */
    function _getFeeInfo(uint128 _fee, uint128 _reducedFee) private pure returns (bool, uint256) {
        bool isCelr = _fee & UINT128_HIBIT == UINT128_HIBIT;
        if (_reducedFee & UINT128_HIBIT == UINT128_HIBIT) {
            _reducedFee = _reducedFee ^ UINT128_HIBIT;
            if (_reducedFee < _fee) {
                _fee = _reducedFee;
            }
        }
        return (isCelr, uint256(_fee));
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
     * @notice Get the hash of the AccountInfo.
     * @param _accountInfo Account info
     */
    function _getAccountInfoHash(dt.AccountInfo memory _accountInfo) private pure returns (bytes32) {
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
                    _accountInfo.timestamp
                )
            );
    }

    /**
     * @notice Get the hash of the StrategyInfo.
     * @param _strategyInfo Strategy info
     */
    function _getStrategyInfoHash(dt.StrategyInfo memory _strategyInfo) private pure returns (bytes32) {
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
    function _getStakingPoolInfoHash(dt.StakingPoolInfo memory _stakingPoolInfo) private pure returns (bytes32) {
        // Here we don't use `abi.encode([struct])` because it's not clear
        // how to generate that encoding client-side.
        return
            keccak256(
                abi.encode(
                    _stakingPoolInfo.shareId,
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
     * @notice Calculates the adjusted stake from staked shares
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
     * @notice Implements sqrt with Babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
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
