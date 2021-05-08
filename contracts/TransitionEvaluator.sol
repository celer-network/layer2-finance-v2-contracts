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

    /**********************
     * External Functions *
     **********************/

    /**
     * @notice Evaluate a transition.
     * @dev Note: most transitions involve one account; the transfer transitions involve two (src, dest).
     * @dev Always returns 3 hashes: accountHash (src), destAccountHash, strategyHash
     *
     * @param _transition The disputed transition.
     * @param _accountInfos The involved account(s) at the start of the disputed transition.
     * @param _strategyInfo The involved strategy at the start of the disputed transition.
     * @param _registry The address of the Registry contract.
     * @return hashes of the accounts and strategy after applying the disputed transition.
     */
    function evaluateTransition(
        bytes calldata _transition,
        dt.AccountInfo[] calldata _accountInfos,
        dt.StrategyInfo calldata _strategyInfo,
        Registry _registry
    ) external view returns (bytes32[3] memory) {
        // Extract the transition type
        uint8 transitionType = tn.extractTransitionType(_transition);
        bytes32[3] memory outputs;
        dt.AccountInfo memory updatedAccountInfo; // single account, or source account for transfers
        dt.AccountInfo memory updatedAccountInfoDest;
        dt.StrategyInfo memory updatedStrategyInfo;

        // Apply the transition and record the resulting storage slots
        if (transitionType == tn.TN_TYPE_DEPOSIT) {
            require(_accountInfos.length == 1, "One account is needed for a deposit transition");
            dt.DepositTransition memory deposit = tn.decodePackedDepositTransition(_transition);
            updatedAccountInfo = _applyDepositTransition(deposit, _accountInfos[0]);
            outputs[0] = _getAccountInfoHash(updatedAccountInfo);
        } else if (transitionType == tn.TN_TYPE_WITHDRAW) {
            require(_accountInfos.length == 1, "One account is needed for a withdraw transition");
            dt.WithdrawTransition memory withdraw = tn.decodePackedWithdrawTransition(_transition);
            updatedAccountInfo = _applyWithdrawTransition(withdraw, _accountInfos[0]);
            outputs[0] = _getAccountInfoHash(updatedAccountInfo);
        } else if (transitionType == tn.TN_TYPE_BUY) {
            require(_accountInfos.length == 1, "One account is needed for a buy transition");
            dt.BuyTransition memory buy = tn.decodePackedBuyTransition(_transition);
            (updatedAccountInfo, updatedStrategyInfo) = _applyBuyTransition(
                buy,
                _accountInfos[0],
                _strategyInfo,
                _registry
            );
            outputs[0] = _getAccountInfoHash(updatedAccountInfo);
            outputs[2] = _getStrategyInfoHash(updatedStrategyInfo);
        } else if (transitionType == tn.TN_TYPE_SELL) {
            require(_accountInfos.length == 1, "One account is needed for a sell transition");
            dt.SellTransition memory sell = tn.decodePackedSellTransition(_transition);
            (updatedAccountInfo, updatedStrategyInfo) = _applySellTransition(sell, _accountInfos[0], _strategyInfo);
            outputs[0] = _getAccountInfoHash(updatedAccountInfo);
            outputs[2] = _getStrategyInfoHash(updatedStrategyInfo);
        } else if (transitionType == tn.TN_TYPE_XFER_ASSET) {
            require(_accountInfos.length == 2, "Two accounts are needed for an asset transfer transition");
            dt.TransferAssetTransition memory xfer = tn.decodePackedTransferAssetTransition(_transition);
            (updatedAccountInfo, updatedAccountInfoDest) = _applyAssetTransferTransition(
                xfer,
                _accountInfos[0],
                _accountInfos[1]
            );
            outputs[0] = _getAccountInfoHash(updatedAccountInfo);
            outputs[1] = _getAccountInfoHash(updatedAccountInfoDest);
        } else if (transitionType == tn.TN_TYPE_XFER_SHARE) {
            require(_accountInfos.length == 2, "Two accounts are needed for a share transfer transition");
            dt.TransferShareTransition memory xfer = tn.decodePackedTransferShareTransition(_transition);
            (updatedAccountInfo, updatedAccountInfoDest) = _applyShareTransferTransition(
                xfer,
                _accountInfos[0],
                _accountInfos[1]
            );
            outputs[0] = _getAccountInfoHash(updatedAccountInfo);
            outputs[1] = _getAccountInfoHash(updatedAccountInfoDest);
        } else if (transitionType == tn.TN_TYPE_AGGREGATE_ORDER) {
            require(_accountInfos.length == 0, "No accounts are needed for an aggregate order transition");
            dt.AggregateOrdersTransition memory aggr = tn.decodePackedAggregateOrdersTransition(_transition);
            updatedStrategyInfo = _applyAggregateOrdersTransition(aggr, _strategyInfo);
            outputs[2] = _getStrategyInfoHash(updatedStrategyInfo);
        } else if (transitionType == tn.TN_TYPE_EXEC_RESULT) {
            require(_accountInfos.length == 0, "No accounts are needed for an execution result transition");
            dt.ExecutionResultTransition memory res = tn.decodePackedExecutionResultTransition(_transition);
            updatedStrategyInfo = _applyExecutionResultTransition(res, _strategyInfo);
            outputs[2] = _getStrategyInfoHash(updatedStrategyInfo);
        } else if (transitionType == tn.TN_TYPE_SETTLE) {
            require(_accountInfos.length == 1, "One account is needed for a settlement transition");
            dt.SettlementTransition memory settle = tn.decodePackedSettlementTransition(_transition);
            (updatedAccountInfo, updatedStrategyInfo) = _applySettlementTransition(
                settle,
                _accountInfos[0],
                _strategyInfo
            );
            outputs[0] = _getAccountInfoHash(updatedAccountInfo);
            outputs[2] = _getStrategyInfoHash(updatedStrategyInfo);
        } else {
            revert("Transition type not recognized");
        }
        return outputs;
    }

    /**
     * @notice Return the (stateRoot, accountId, accountIdDest, strategyId) for this transition.
     * @dev Note: most transitions involve one account; the transfer transitions involve a 2nd account (dest).
     */
    function getTransitionStateRootAndAccessIds(bytes calldata _rawTransition)
        external
        pure
        returns (
            bytes32,
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
        } else if (transitionType == tn.TN_TYPE_INIT) {
            dt.InitTransition memory transition = tn.decodeInitTransition(rawTransition);
            stateRoot = transition.stateRoot;
        } else {
            revert("Transition type not recognized");
        }
        return (stateRoot, accountId, accountIdDest, strategyId);
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
     * @return new account info after applying the disputed transition
     */
    function _applyWithdrawTransition(dt.WithdrawTransition memory _transition, dt.AccountInfo memory _accountInfo)
        private
        pure
        returns (dt.AccountInfo memory)
    {
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
        bytes32 prefixedHash = ECDSA.toEthSignedMessageHash(txHash);
        require(
            ECDSA.recover(prefixedHash, _transition.v, _transition.r, _transition.s) == _accountInfo.account,
            "Withdraw signature is invalid"
        );

        require(_accountInfo.accountId == _transition.accountId, "account id not match");
        require(_accountInfo.timestamp < _transition.timestamp, "timestamp should be monotonically increasing");
        _accountInfo.timestamp = _transition.timestamp;

        _accountInfo.idleAssets[_transition.assetId] = _accountInfo.idleAssets[_transition.assetId].sub(
            _transition.amount
        );

        return _accountInfo;
    }

    /**
     * @notice Apply a BuyTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @return new account and strategy info after applying the disputed transition
     */
    function _applyBuyTransition(
        dt.BuyTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StrategyInfo memory _strategyInfo,
        Registry _registry
    ) private view returns (dt.AccountInfo memory, dt.StrategyInfo memory) {
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
        bytes32 prefixedHash = ECDSA.toEthSignedMessageHash(txHash);
        require(
            ECDSA.recover(prefixedHash, _transition.v, _transition.r, _transition.s) == _accountInfo.account,
            "Buy signature is invalid"
        );

        require(_accountInfo.accountId == _transition.accountId, "account id not match");
        require(_accountInfo.timestamp < _transition.timestamp, "timestamp should be monotonically increasing");
        _accountInfo.timestamp = _transition.timestamp;

        uint32 stId = _transition.strategyId;
        if (_strategyInfo.assetId == 0) {
            // first time commit of new strategy
            require(_strategyInfo.shareSupply == 0, "empty strategy shareSupply must be zero");
            require(_strategyInfo.nextAggregateId == 0, "empty strategy nextAggregateId must be zero");
            require(_strategyInfo.lastExecAggregateId == 0, "empty strategy lastExecAggregateId must be zero");
            require(_strategyInfo.pending.length == 0, "empty strategy pending must be empty");

            address strategyAddr = _registry.strategyIndexToAddress(stId);
            address assetAddr = IStrategy(strategyAddr).getAssetAddress();
            _strategyInfo.assetId = _registry.assetAddressToIndex(assetAddr);
        }

        uint32 assetId = _strategyInfo.assetId;
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

        _strategyInfo.pending[npend - 1].buyAmount = _strategyInfo.pending[npend - 1].buyAmount.add(_transition.amount);
        _accountInfo.idleAssets[assetId] = _accountInfo.idleAssets[assetId].sub(_transition.amount);

        _adjustAccountPendingEntries(_accountInfo, stId, _strategyInfo.nextAggregateId);
        npend = _accountInfo.pending[stId].length;
        dt.PendingAccountInfo memory pai = _accountInfo.pending[stId][npend - 1];
        _accountInfo.pending[stId][npend - 1].buyAmount = pai.buyAmount.add(_transition.amount);
        _accountInfo.pending[stId][npend - 1].buyFees = pai.buyFees.add(_transition.fee);

        return (_accountInfo, _strategyInfo);
    }

    /**
     * @notice Apply a SellTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @return new account and strategy info after applying the disputed transition
     */
    function _applySellTransition(
        dt.SellTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StrategyInfo memory _strategyInfo
    ) private pure returns (dt.AccountInfo memory, dt.StrategyInfo memory) {
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
        bytes32 prefixedHash = ECDSA.toEthSignedMessageHash(txHash);
        require(
            ECDSA.recover(prefixedHash, _transition.v, _transition.r, _transition.s) == _accountInfo.account,
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
        } else if (_strategyInfo.pending[npend - 1].minSharePriceForSell > _transition.minSharePrice) {
            _strategyInfo.pending[npend - 1].minSharePriceForSell = _transition.minSharePrice;
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
        _accountInfo.pending[stId][npend - 1].sellFees = pai.sellFees.add(_transition.fee);

        return (_accountInfo, _strategyInfo);
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
     * @return new account and strategy info after applying the disputed transition
     */
    function _applySettlementTransition(
        dt.SettlementTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StrategyInfo memory _strategyInfo
    ) private pure returns (dt.AccountInfo memory, dt.StrategyInfo memory) {
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
                _accountInfo.idleAssets[assetId] = _accountInfo.idleAssets[assetId].add(amount);
                stPend.unsettledSellShares = stPend.unsettledSellShares.sub(acctPend.sellShares);
            }
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
        }

        _popHeadAccountPendingEntries(_accountInfo, stId);
        if (stPend.unsettledBuyAmount == 0 && stPend.unsettledSellShares == 0) {
            _popHeadStrategyPendingEntries(_strategyInfo);
        }

        return (_accountInfo, _strategyInfo);
    }

    /**
     * @notice Apply a TransferAssetTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition (source of the transfer).
     * @param _accountInfoDest The involved destination account from the previous transition.
     * @return new account info for both accounts after applying the disputed transition
     */
    function _applyAssetTransferTransition(
        dt.TransferAssetTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.AccountInfo memory _accountInfoDest
    ) private pure returns (dt.AccountInfo memory, dt.AccountInfo memory) {
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
        bytes32 prefixedHash = ECDSA.toEthSignedMessageHash(txHash);
        require(
            ECDSA.recover(prefixedHash, _transition.v, _transition.r, _transition.s) == _accountInfo.account,
            "Transfer assets signature is invalid"
        );

        require(_accountInfo.accountId == _transition.fromAccountId, "source account id not match");
        require(_accountInfoDest.accountId == _transition.toAccountId, "destination account id not match");
        require(_accountInfo.timestamp < _transition.timestamp, "timestamp should be monotonically increasing");
        _accountInfo.timestamp = _transition.timestamp;

        uint32 assetId = _transition.assetId;
        _adjustAccountIdleAssetEntries(_accountInfoDest, assetId);
        _accountInfo.idleAssets[assetId] = _accountInfo.idleAssets[assetId].sub(_transition.amount);
        _accountInfoDest.idleAssets[assetId] = _accountInfoDest.idleAssets[assetId].add(_transition.amount);

        return (_accountInfo, _accountInfoDest);
    }

    /**
     * @notice Apply a TransferShareTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition (source of the transfer).
     * @param _accountInfoDest The involved destination account from the previous transition.
     * @return new account info for both accounts after applying the disputed transition
     */
    function _applyShareTransferTransition(
        dt.TransferShareTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.AccountInfo memory _accountInfoDest
    ) private pure returns (dt.AccountInfo memory, dt.AccountInfo memory) {
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
        bytes32 prefixedHash = ECDSA.toEthSignedMessageHash(txHash);
        require(
            ECDSA.recover(prefixedHash, _transition.v, _transition.r, _transition.s) == _accountInfo.account,
            "Transfer shares signature is invalid"
        );

        require(_accountInfo.accountId == _transition.fromAccountId, "source account id not match");
        require(_accountInfoDest.accountId == _transition.toAccountId, "destination account id not match");
        require(_accountInfo.timestamp < _transition.timestamp, "timestamp should be monotonically increasing");
        _accountInfo.timestamp = _transition.timestamp;

        uint32 stId = _transition.strategyId;
        _adjustAccountShareEntries(_accountInfoDest, stId);
        _accountInfo.shares[stId] = _accountInfo.shares[stId].sub(_transition.shares);
        _accountInfoDest.shares[stId] = _accountInfoDest.shares[stId].add(_transition.shares);

        return (_accountInfo, _accountInfoDest);
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
     * Get the hash of the StrategyInfo.
     */
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
}
