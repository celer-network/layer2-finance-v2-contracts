// SPDX-License-Identifier: MIT

// 1st part of the transition applier due to contract size restrictions

pragma solidity 0.8.6;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/* Internal Imports */
import {DataTypes as dt} from "./libraries/DataTypes.sol";
import {Transitions as tn} from "./libraries/Transitions.sol";
import "./libraries/ErrMsg.sol";
import "./interfaces/IStrategy.sol";
import "./Registry.sol";

contract TransitionApplier1 {
    uint128 public constant UINT128_MAX = 2**128 - 1;

    /**********************
     * External Functions *
     **********************/

    /**
     * @notice Apply a DepositTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @return new account info after applying the disputed transition
     */
    function applyDepositTransition(dt.DepositTransition memory _transition, dt.AccountInfo memory _accountInfo)
        public
        pure
        returns (dt.AccountInfo memory)
    {
        require(_transition.account != address(0), ErrMsg.REQ_BAD_ACCT);
        if (_accountInfo.account == address(0)) {
            // first time deposit of this account
            require(_accountInfo.accountId == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfo.idleAssets.length == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfo.shares.length == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfo.pending.length == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfo.timestamp == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            _accountInfo.account = _transition.account;
            _accountInfo.accountId = _transition.accountId;
        } else {
            require(_accountInfo.account == _transition.account, ErrMsg.REQ_BAD_ACCT);
            require(_accountInfo.accountId == _transition.accountId, ErrMsg.REQ_BAD_ACCT);
        }

        uint32 assetId = _transition.assetId;
        tn.adjustAccountIdleAssetEntries(_accountInfo, assetId);
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
    function applyWithdrawTransition(
        dt.WithdrawTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.GlobalInfo memory _globalInfo
    ) public pure returns (dt.AccountInfo memory, dt.GlobalInfo memory) {
        bytes32 txHash = keccak256(
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
            ErrMsg.REQ_BAD_SIG
        );

        require(_accountInfo.accountId == _transition.accountId, ErrMsg.REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, ErrMsg.REQ_BAD_TS);
        _accountInfo.timestamp = _transition.timestamp;

        _accountInfo.idleAssets[_transition.assetId] -= _transition.amount;
        tn.addProtoFee(_globalInfo, _transition.assetId, _transition.fee);

        return (_accountInfo, _globalInfo);
    }

    /**
     * @notice Apply a BuyTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @return new account, strategy info, and global info after applying the disputed transition
     */
    function applyBuyTransition(
        dt.BuyTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StrategyInfo memory _strategyInfo,
        Registry _registry
    ) public view returns (dt.AccountInfo memory, dt.StrategyInfo memory) {
        bytes32 txHash = keccak256(
            abi.encodePacked(
                _transition.transitionType,
                _transition.strategyId,
                _transition.amount,
                _transition.maxSharePrice,
                _transition.fee,
                _transition.timestamp
            )
        );
        require(
            ECDSA.recover(ECDSA.toEthSignedMessageHash(txHash), _transition.v, _transition.r, _transition.s) ==
                _accountInfo.account,
            ErrMsg.REQ_BAD_SIG
        );

        require(_accountInfo.accountId == _transition.accountId, ErrMsg.REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, ErrMsg.REQ_BAD_TS);
        _accountInfo.timestamp = _transition.timestamp;

        if (_strategyInfo.assetId == 0) {
            // first time commit of new strategy
            require(_strategyInfo.shareSupply == 0, ErrMsg.REQ_ST_NOT_EMPTY);
            require(_strategyInfo.nextAggregateId == 0, ErrMsg.REQ_ST_NOT_EMPTY);
            require(_strategyInfo.lastExecAggregateId == 0, ErrMsg.REQ_ST_NOT_EMPTY);
            require(_strategyInfo.pending.length == 0, ErrMsg.REQ_ST_NOT_EMPTY);

            address strategyAddr = _registry.strategyIndexToAddress(_transition.strategyId);
            address assetAddr = IStrategy(strategyAddr).getAssetAddress();
            _strategyInfo.assetId = _registry.assetAddressToIndex(assetAddr);
        }
        _accountInfo.idleAssets[_strategyInfo.assetId] -= _transition.amount;

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

        uint256 buyAmount = _transition.amount;
        (bool isCelr, uint256 fee) = tn.getFeeInfo(_transition.fee);
        if (isCelr) {
            _accountInfo.idleAssets[1] -= fee;
        } else {
            buyAmount -= fee;
        }

        _strategyInfo.pending[npend - 1].buyAmount += buyAmount;

        _adjustAccountPendingEntries(_accountInfo, _transition.strategyId, _strategyInfo.nextAggregateId);
        npend = _accountInfo.pending[_transition.strategyId].length;
        _accountInfo.pending[_transition.strategyId][npend - 1].buyAmount += buyAmount;
        if (isCelr) {
            _accountInfo.pending[_transition.strategyId][npend - 1].celrFees += fee;
        } else {
            _accountInfo.pending[_transition.strategyId][npend - 1].buyFees += fee;
        }

        return (_accountInfo, _strategyInfo);
    }

    /**
     * @notice Apply a SellTransition.
     *
     * @param _transition The disputed transition.
     * @param _accountInfo The involved account from the previous transition.
     * @param _strategyInfo The involved strategy from the previous transition.
     * @return new account, strategy info, and global info after applying the disputed transition
     */
    function applySellTransition(
        dt.SellTransition memory _transition,
        dt.AccountInfo memory _accountInfo,
        dt.StrategyInfo memory _strategyInfo
    ) external pure returns (dt.AccountInfo memory, dt.StrategyInfo memory) {
        bytes32 txHash = keccak256(
            abi.encodePacked(
                _transition.transitionType,
                _transition.strategyId,
                _transition.shares,
                _transition.minSharePrice,
                _transition.fee,
                _transition.timestamp
            )
        );
        require(
            ECDSA.recover(ECDSA.toEthSignedMessageHash(txHash), _transition.v, _transition.r, _transition.s) ==
                _accountInfo.account,
            ErrMsg.REQ_BAD_SIG
        );

        require(_accountInfo.accountId == _transition.accountId, ErrMsg.REQ_BAD_ACCT);
        require(_accountInfo.timestamp < _transition.timestamp, ErrMsg.REQ_BAD_TS);
        require(_strategyInfo.assetId > 0, ErrMsg.REQ_BAD_ST);
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

        (bool isCelr, uint256 fee) = tn.getFeeInfo(_transition.fee);
        if (isCelr) {
            _accountInfo.idleAssets[1] -= fee;
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

        return (_accountInfo, _strategyInfo);
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
        require(aggrId <= _strategyInfo.lastExecAggregateId, ErrMsg.REQ_BAD_AGGR);
        require(_strategyInfo.pending.length > 0, ErrMsg.REQ_NO_PEND);
        require(aggrId == _strategyInfo.pending[0].aggregateId, ErrMsg.REQ_BAD_AGGR);
        require(_accountInfo.pending.length > stId, ErrMsg.REQ_BAD_ST);
        require(_accountInfo.pending[stId].length > 0, ErrMsg.REQ_NO_PEND);
        require(aggrId == _accountInfo.pending[stId][0].aggregateId, ErrMsg.REQ_BAD_AGGR);

        dt.PendingStrategyInfo memory stPend = _strategyInfo.pending[0];
        dt.PendingAccountInfo memory acctPend = _accountInfo.pending[stId][0];

        if (stPend.executionSucceed) {
            uint256 assetRefund = _transition.assetRefund;
            uint256 celrRefund = _transition.celrRefund;
            if (acctPend.buyAmount > 0) {
                tn.adjustAccountShareEntries(_accountInfo, stId);
                uint256 shares = (acctPend.buyAmount * stPend.sharesFromBuy) / stPend.buyAmount;
                _accountInfo.shares[stId] += shares;
                stPend.unsettledBuyAmount -= acctPend.buyAmount;
            }
            if (acctPend.sellShares > 0) {
                tn.adjustAccountIdleAssetEntries(_accountInfo, assetId);
                uint256 amount = (acctPend.sellShares * stPend.amountFromSell) / stPend.sellShares;
                uint256 fee = acctPend.sellFees;
                if (fee < assetRefund) {
                    assetRefund -= fee;
                    fee = 0;
                } else {
                    fee -= assetRefund;
                    assetRefund = 0;
                }
                if (amount < fee) {
                    fee = amount;
                }
                amount -= fee;
                tn.addProtoFee(_globalInfo, assetId, fee);
                _accountInfo.idleAssets[assetId] += amount;
                stPend.unsettledSellShares -= acctPend.sellShares;
            }
            _accountInfo.idleAssets[assetId] += assetRefund;
            tn.addProtoFee(_globalInfo, assetId, acctPend.buyFees - assetRefund);
            _accountInfo.idleAssets[1] += celrRefund;
            tn.addProtoFee(_globalInfo, 1, acctPend.celrFees - celrRefund);
        } else {
            if (acctPend.buyAmount > 0) {
                tn.adjustAccountIdleAssetEntries(_accountInfo, assetId);
                _accountInfo.idleAssets[assetId] += acctPend.buyAmount;
                stPend.unsettledBuyAmount -= acctPend.buyAmount;
            }
            if (acctPend.sellShares > 0) {
                tn.adjustAccountShareEntries(_accountInfo, stId);
                _accountInfo.shares[stId] += acctPend.sellShares;
                stPend.unsettledSellShares -= acctPend.sellShares;
            }
            _accountInfo.idleAssets[assetId] += acctPend.buyFees;
            _accountInfo.idleAssets[1] += acctPend.celrFees;
        }

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
        bytes32 txHash = keccak256(
            abi.encodePacked(
                _transition.transitionType,
                _transition.toAccount,
                _transition.assetId,
                _transition.amount,
                _transition.fee,
                _transition.timestamp
            )
        );
        require(
            ECDSA.recover(ECDSA.toEthSignedMessageHash(txHash), _transition.v, _transition.r, _transition.s) ==
                _accountInfo.account,
            ErrMsg.REQ_BAD_SIG
        );
        require(_accountInfo.accountId == _transition.fromAccountId, ErrMsg.REQ_BAD_ACCT);

        if (_accountInfoDest.account == address(0)) {
            // transfer to a new account
            require(_accountInfoDest.accountId == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfoDest.idleAssets.length == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfoDest.shares.length == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfoDest.pending.length == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfoDest.timestamp == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            _accountInfoDest.account = _transition.toAccount;
            _accountInfoDest.accountId = _transition.toAccountId;
        } else {
            require(_accountInfoDest.account == _transition.toAccount, ErrMsg.REQ_BAD_ACCT);
            require(_accountInfoDest.accountId == _transition.toAccountId, ErrMsg.REQ_BAD_ACCT);
        }

        require(_accountInfo.timestamp < _transition.timestamp, ErrMsg.REQ_BAD_TS);
        _accountInfo.timestamp = _transition.timestamp;

        uint32 assetId = _transition.assetId;
        uint256 amount = _transition.amount;
        (bool isCelr, uint256 fee) = tn.getFeeInfo(_transition.fee);
        if (isCelr) {
            _accountInfo.idleAssets[1] -= fee;
            tn.updateOpFee(_globalInfo, true, 1, fee);
        } else {
            amount -= fee;
            tn.updateOpFee(_globalInfo, true, assetId, fee);
        }

        tn.adjustAccountIdleAssetEntries(_accountInfoDest, assetId);
        _accountInfo.idleAssets[assetId] -= _transition.amount;
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
        bytes32 txHash = keccak256(
            abi.encodePacked(
                _transition.transitionType,
                _transition.toAccount,
                _transition.strategyId,
                _transition.shares,
                _transition.fee,
                _transition.timestamp
            )
        );
        require(
            ECDSA.recover(ECDSA.toEthSignedMessageHash(txHash), _transition.v, _transition.r, _transition.s) ==
                _accountInfo.account,
            ErrMsg.REQ_BAD_SIG
        );
        require(_accountInfo.accountId == _transition.fromAccountId, ErrMsg.REQ_BAD_ACCT);

        if (_accountInfoDest.account == address(0)) {
            // transfer to a new account
            require(_accountInfoDest.accountId == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfoDest.idleAssets.length == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfoDest.shares.length == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfoDest.pending.length == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            require(_accountInfoDest.timestamp == 0, ErrMsg.REQ_ACCT_NOT_EMPTY);
            _accountInfoDest.account = _transition.toAccount;
            _accountInfoDest.accountId = _transition.toAccountId;
        } else {
            require(_accountInfoDest.account == _transition.toAccount, ErrMsg.REQ_BAD_ACCT);
            require(_accountInfoDest.accountId == _transition.toAccountId, ErrMsg.REQ_BAD_ACCT);
        }

        require(_accountInfo.timestamp < _transition.timestamp, ErrMsg.REQ_BAD_TS);
        _accountInfo.timestamp = _transition.timestamp;

        uint32 stId = _transition.strategyId;
        uint256 shares = _transition.shares;
        (bool isCelr, uint256 fee) = tn.getFeeInfo(_transition.fee);
        if (isCelr) {
            _accountInfo.idleAssets[1] -= fee;
            tn.updateOpFee(_globalInfo, true, 1, fee);
        } else {
            shares -= fee;
            tn.updateOpFee(_globalInfo, false, stId, fee);
        }

        tn.adjustAccountShareEntries(_accountInfoDest, stId);
        _accountInfo.shares[stId] -= _transition.shares;
        _accountInfoDest.shares[stId] += shares;

        return (_accountInfo, _accountInfoDest, _globalInfo);
    }

    /*********************
     * Private Functions *
     *********************/

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
}
