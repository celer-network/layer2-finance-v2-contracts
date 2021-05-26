// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;
pragma abicoder v2;

import "../libraries/DataTypes.sol";

library Transitions {
    // Transition Types
    uint8 public constant TN_TYPE_INVALID = 0;
    uint8 public constant TN_TYPE_INIT = 1;
    uint8 public constant TN_TYPE_DEPOSIT = 2;
    uint8 public constant TN_TYPE_WITHDRAW = 3;
    uint8 public constant TN_TYPE_BUY = 4;
    uint8 public constant TN_TYPE_SELL = 5;
    uint8 public constant TN_TYPE_XFER_ASSET = 6;
    uint8 public constant TN_TYPE_XFER_SHARE = 7;
    uint8 public constant TN_TYPE_AGGREGATE_ORDER = 8;
    uint8 public constant TN_TYPE_EXEC_RESULT = 9;
    uint8 public constant TN_TYPE_SETTLE = 10;
    uint8 public constant TN_TYPE_WITHDRAW_PROTO_FEE = 11;
    uint8 public constant TN_TYPE_XFER_OP_FEE = 12;
    // Liquidity Mining
    uint8 public constant TN_TYPE_STAKE = 13;
    uint8 public constant TN_TYPE_UNSTAKE = 14;
    uint8 public constant TN_TYPE_UPDATE_POOL_INFO = 15;
    uint8 public constant TN_TYPE_DEPOSIT_REWARD = 16;

    // fee encoding
    uint128 public constant UINT128_HIBIT = 2**127;

    function extractTransitionType(bytes memory _bytes) internal pure returns (uint8) {
        uint8 transitionType;
        assembly {
            transitionType := mload(add(_bytes, 0x20))
        }
        return transitionType;
    }

    function decodeInitTransition(bytes memory _rawBytes) internal pure returns (DataTypes.InitTransition memory) {
        (uint8 transitionType, bytes32 stateRoot) = abi.decode((_rawBytes), (uint8, bytes32));
        DataTypes.InitTransition memory transition = DataTypes.InitTransition(transitionType, stateRoot);
        return transition;
    }

    function decodePackedDepositTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.DepositTransition memory)
    {
        (uint128 infoCode, bytes32 stateRoot, address account, uint256 amount) =
            abi.decode((_rawBytes), (uint128, bytes32, address, uint256));
        (uint32 accountId, uint32 assetId, uint8 transitionType) = decodeDepositInfoCode(infoCode);
        DataTypes.DepositTransition memory transition =
            DataTypes.DepositTransition(transitionType, stateRoot, account, accountId, assetId, amount);
        return transition;
    }

    function decodeDepositInfoCode(uint128 _infoCode)
        internal
        pure
        returns (
            uint32, // accountId
            uint32, // assetId
            uint8 // transitionType
        )
    {
        (uint64 high, uint64 low) = splitUint128(_infoCode);
        (uint32 accountId, uint32 assetId) = splitUint64(high);
        uint8 transitionType = uint8(low);
        return (accountId, assetId, transitionType);
    }

    function decodePackedWithdrawTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.WithdrawTransition memory)
    {
        (uint256 infoCode, bytes32 stateRoot, address account, uint256 amtfee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, address, uint256, bytes32, bytes32));
        (uint32 accountId, uint32 assetId, uint64 timestamp, uint8 v, uint8 transitionType) =
            decodeWithdrawInfoCode(infoCode);
        (uint128 amount, uint128 fee) = splitUint256(amtfee);
        DataTypes.WithdrawTransition memory transition =
            DataTypes.WithdrawTransition(
                transitionType,
                stateRoot,
                account,
                accountId,
                assetId,
                amount,
                fee,
                timestamp,
                r,
                s,
                v
            );
        return transition;
    }

    function decodeWithdrawInfoCode(uint256 _infoCode)
        internal
        pure
        returns (
            uint32, // accountId
            uint32, // assetId
            uint64, // timestamp
            uint8, // sig-v
            uint8 // transitionType
        )
    {
        (uint128 high, uint128 low) = splitUint256(_infoCode);
        (uint64 ids, uint64 timestamp) = splitUint128(high);
        (uint32 accountId, uint32 assetId) = splitUint64(ids);
        (uint8 v, uint8 transitionType) = splitUint16(uint16(low));
        return (accountId, assetId, timestamp, v, transitionType);
    }

    function decodePackedBuyTransition(bytes memory _rawBytes) internal pure returns (DataTypes.BuyTransition memory) {
        (uint256 infoCode, bytes32 stateRoot, uint256 amtfee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, bytes32, bytes32));
        (uint32 accountId, uint32 strategyId, uint64 timestamp, uint128 maxSharePrice, uint8 v, uint8 transitionType) =
            decodeBuySellInfoCode(infoCode);
        (uint128 amount, uint128 fee) = splitUint256(amtfee);
        DataTypes.BuyTransition memory transition =
            DataTypes.BuyTransition(
                transitionType,
                stateRoot,
                accountId,
                strategyId,
                amount,
                maxSharePrice,
                fee,
                timestamp,
                r,
                s,
                v
            );
        return transition;
    }

    function decodePackedSellTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.SellTransition memory)
    {
        (uint256 infoCode, bytes32 stateRoot, uint256 sharefee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, bytes32, bytes32));
        (uint32 accountId, uint32 strategyId, uint64 timestamp, uint128 minSharePrice, uint8 v, uint8 transitionType) =
            decodeBuySellInfoCode(infoCode);
        (uint128 shares, uint128 fee) = splitUint256(sharefee);
        DataTypes.SellTransition memory transition =
            DataTypes.SellTransition(
                transitionType,
                stateRoot,
                accountId,
                strategyId,
                shares,
                minSharePrice,
                fee,
                timestamp,
                r,
                s,
                v
            );
        return transition;
    }

    function decodeBuySellInfoCode(uint256 _infoCode)
        internal
        pure
        returns (
            uint32, // accountId
            uint32, // strategyId
            uint64, // timestamp
            uint128, // maxSharePrice or minSharePrice
            uint8, // sig-v
            uint8 // transitionType
        )
    {
        (uint128 h1, uint128 low) = splitUint256(_infoCode);
        (uint64 h2, uint64 timestamp) = splitUint128(h1);
        (uint32 accountId, uint32 strategyId) = splitUint64(h2);
        uint128 sharePrice = uint128(low >> 16);
        (uint8 v, uint8 transitionType) = splitUint16(uint16(low));
        return (accountId, strategyId, timestamp, sharePrice, v, transitionType);
    }

    function decodePackedTransferAssetTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.TransferAssetTransition memory)
    {
        (uint256 infoCode, bytes32 stateRoot, address toAccount, uint256 amtfee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, address, uint256, bytes32, bytes32));
        (uint32 assetId, uint32 fromAccountId, uint32 toAccountId, uint64 timestamp, uint8 v, uint8 transitionType) =
            decodeTransferInfoCode(infoCode);
        (uint128 amount, uint128 fee) = splitUint256(amtfee);
        DataTypes.TransferAssetTransition memory transition =
            DataTypes.TransferAssetTransition(
                transitionType,
                stateRoot,
                fromAccountId,
                toAccountId,
                toAccount,
                assetId,
                amount,
                fee,
                timestamp,
                r,
                s,
                v
            );
        return transition;
    }

    function decodePackedTransferShareTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.TransferShareTransition memory)
    {
        (uint256 infoCode, bytes32 stateRoot, address toAccount, uint256 sharefee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, address, uint256, bytes32, bytes32));
        (uint32 strategyId, uint32 fromAccountId, uint32 toAccountId, uint64 timestamp, uint8 v, uint8 transitionType) =
            decodeTransferInfoCode(infoCode);
        (uint128 shares, uint128 fee) = splitUint256(sharefee);
        DataTypes.TransferShareTransition memory transition =
            DataTypes.TransferShareTransition(
                transitionType,
                stateRoot,
                fromAccountId,
                toAccountId,
                toAccount,
                strategyId,
                shares,
                fee,
                timestamp,
                r,
                s,
                v
            );
        return transition;
    }

    function decodeTransferInfoCode(uint256 _infoCode)
        internal
        pure
        returns (
            uint32, // assetId or strategyId
            uint32, // fromAccountId
            uint32, // toAccountId
            uint64, // timestamp
            uint8, // sig-v
            uint8 // transitionType
        )
    {
        (uint128 high, uint128 low) = splitUint256(_infoCode);
        (uint64 astId, uint64 acctIds) = splitUint128(high);
        (uint32 fromAccountId, uint32 toAccountId) = splitUint64(acctIds);
        (uint64 timestamp, uint64 vt) = splitUint128(low);
        (uint8 v, uint8 transitionType) = splitUint16(uint16(vt));
        return (uint32(astId), fromAccountId, toAccountId, timestamp, v, transitionType);
    }

    function decodePackedSettlementTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.SettlementTransition memory)
    {
        (uint256 infoCode, bytes32 stateRoot) = abi.decode((_rawBytes), (uint256, bytes32));
        (
            uint32 accountId,
            uint32 strategyId,
            uint64 aggregateId,
            uint128 celrRefund,
            uint128 assetRefund,
            uint8 transitionType
        ) = decodeSettlementInfoCode(infoCode);
        DataTypes.SettlementTransition memory transition =
            DataTypes.SettlementTransition(
                transitionType,
                stateRoot,
                strategyId,
                aggregateId,
                accountId,
                celrRefund,
                assetRefund
            );
        return transition;
    }

    function decodeSettlementInfoCode(uint256 _infoCode)
        internal
        pure
        returns (
            uint32, // accountId
            uint32, // strategyId
            uint64, // aggregateId
            uint128, // celrRefund
            uint128, // assetRefund
            uint8 // transitionType
        )
    {
        uint128 ids = uint128(_infoCode >> 160);
        uint64 aggregateId = uint32(ids);
        ids = uint64(ids >> 32);
        uint32 strategyId = uint32(ids);
        uint32 accountId = uint32(ids >> 32);
        uint256 refund = uint152(_infoCode >> 8);
        uint128 assetRefund = uint128(refund);
        uint128 celrRefund = uint128(refund >> 96) * 1e9;
        uint8 transitionType = uint8(_infoCode);
        return (accountId, strategyId, aggregateId, celrRefund, assetRefund, transitionType);
    }

    function decodePackedAggregateOrdersTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.AggregateOrdersTransition memory)
    {
        (
            uint64 infoCode,
            bytes32 stateRoot,
            uint256 buyAmount,
            uint256 sellShares,
            uint256 minSharesFromBuy,
            uint256 minAmountFromSell
        ) = abi.decode((_rawBytes), (uint64, bytes32, uint256, uint256, uint256, uint256));
        (uint32 strategyId, uint8 transitionType) = decodeAggregateOrdersInfoCode(infoCode);
        DataTypes.AggregateOrdersTransition memory transition =
            DataTypes.AggregateOrdersTransition(
                transitionType,
                stateRoot,
                strategyId,
                buyAmount,
                sellShares,
                minSharesFromBuy,
                minAmountFromSell
            );
        return transition;
    }

    function decodeAggregateOrdersInfoCode(uint64 _infoCode)
        internal
        pure
        returns (
            uint32, // strategyId
            uint8 // transitionType
        )
    {
        (uint32 strategyId, uint32 low) = splitUint64(_infoCode);
        uint8 transitionType = uint8(low);
        return (strategyId, transitionType);
    }

    function decodePackedExecutionResultTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.ExecutionResultTransition memory)
    {
        (uint256 infoCode, bytes32 stateRoot, uint256 sharesFromBuy, uint256 amountFromSell) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, uint256));
        (uint64 currEpoch, uint64 aggregateId, uint32 strategyId, bool success, uint8 transitionType) =
            decodeExecutionResultInfoCode(infoCode);
        DataTypes.ExecutionResultTransition memory transition =
            DataTypes.ExecutionResultTransition(
                transitionType,
                stateRoot,
                strategyId,
                aggregateId,
                success,
                sharesFromBuy,
                amountFromSell,
                currEpoch
            );
        return transition;
    }

    function decodeExecutionResultInfoCode(uint256 _infoCode)
        internal
        pure
        returns (
            uint64, // currEpoch,
            uint64, // aggregateId
            uint32, // strategyId
            bool, // success
            uint8 // transitionType
        )
    {
        (uint128 high, uint128 low) = splitUint256(_infoCode);
        (, uint64 currEpoch) = splitUint128(high);
        (uint64 aggregateId, uint64 low2) = splitUint128(low);
        (uint32 strategyId, uint32 low3) = splitUint64(low2);
        uint8 transitionType = uint8(low3);
        bool success = uint8(low3 >> 8) == 1;
        return (currEpoch, aggregateId, strategyId, success, transitionType);
    }

    function decodePackedStakeTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.StakeTransition memory)
    {
        (uint256 infoCode, bytes32 stateRoot, uint256 sharefee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, bytes32, bytes32));
        (uint32 poolId, uint32 accountId, uint64 timestamp, uint8 v, uint8 transitionType) =
            decodeStakingInfoCode(infoCode);
        (uint128 shares, uint128 fee) = splitUint256(sharefee);
        DataTypes.StakeTransition memory transition =
            DataTypes.StakeTransition(transitionType, stateRoot, poolId, accountId, shares, fee, timestamp, r, s, v);
        return transition;
    }

    function decodePackedUnstakeTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.UnstakeTransition memory)
    {
        (uint256 infoCode, bytes32 stateRoot, uint256 sharefee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, bytes32, bytes32));
        (uint32 poolId, uint32 accountId, uint64 timestamp, uint8 v, uint8 transitionType) =
            decodeStakingInfoCode(infoCode);
        (uint128 shares, uint128 fee) = splitUint256(sharefee);
        DataTypes.UnstakeTransition memory transition =
            DataTypes.UnstakeTransition(transitionType, stateRoot, poolId, accountId, shares, fee, timestamp, r, s, v);
        return transition;
    }

    function decodeStakingInfoCode(uint256 _infoCode)
        internal
        pure
        returns (
            uint32, // poolId
            uint32, // accountId
            uint64, // timestamp
            uint8, // sig-v
            uint8 // transitionType
        )
    {
        (uint128 high, uint128 low) = splitUint256(_infoCode);
        (, uint64 poolIdAccountId) = splitUint128(high);
        (uint32 poolId, uint32 accountId) = splitUint64(poolIdAccountId);
        (uint64 timestamp, uint64 vt) = splitUint128(low);
        (uint8 v, uint8 transitionType) = splitUint16(uint16(vt));
        return (poolId, accountId, timestamp, v, transitionType);
    }

    function decodeUpdatePoolInfoTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.UpdatePoolInfoTransition memory)
    {
        (
            uint8 transitionType,
            bytes32 stateRoot,
            uint32 poolId,
            uint32 strategyId,
            uint32[] memory rewardAssetIds,
            uint256[] memory rewardPerEpoch,
            uint256 stakeAdjustmentFactor
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint32, uint32, uint32[], uint256[], uint256));
        DataTypes.UpdatePoolInfoTransition memory transition =
            DataTypes.UpdatePoolInfoTransition(
                transitionType,
                stateRoot,
                poolId,
                strategyId,
                rewardAssetIds,
                rewardPerEpoch,
                stakeAdjustmentFactor
            );
        return transition;
    }

    function decodeDepositRewardTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.DepositRewardTransition memory)
    {
        (uint8 transitionType, bytes32 stateRoot, uint32 assetId, uint256 amount) =
            abi.decode((_rawBytes), (uint8, bytes32, uint32, uint256));
        DataTypes.DepositRewardTransition memory transition =
            DataTypes.DepositRewardTransition(transitionType, stateRoot, assetId, amount);
        return transition;
    }

    function decodeWithdrawProtocolFeeTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.WithdrawProtocolFeeTransition memory)
    {
        (uint8 transitionType, bytes32 stateRoot, uint32 assetId, uint256 amount) =
            abi.decode((_rawBytes), (uint8, bytes32, uint32, uint256));
        DataTypes.WithdrawProtocolFeeTransition memory transition =
            DataTypes.WithdrawProtocolFeeTransition(transitionType, stateRoot, assetId, amount);
        return transition;
    }

    function decodeTransferOperatorFeeTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.TransferOperatorFeeTransition memory)
    {
        (uint8 transitionType, bytes32 stateRoot, uint32 accountId) = abi.decode((_rawBytes), (uint8, bytes32, uint32));
        DataTypes.TransferOperatorFeeTransition memory transition =
            DataTypes.TransferOperatorFeeTransition(transitionType, stateRoot, accountId);
        return transition;
    }

    /**
     * Helper to expand the account array of idle assets if needed.
     */
    function adjustAccountIdleAssetEntries(DataTypes.AccountInfo memory _accountInfo, uint32 assetId) internal pure {
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
     * Helper to expand the account array of shares if needed.
     */
    function adjustAccountShareEntries(DataTypes.AccountInfo memory _accountInfo, uint32 stId) internal pure {
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
     * Helper to expand protocol fee array (if needed) and add given fee.
     */
    function addProtoFee(
        DataTypes.GlobalInfo memory _globalInfo,
        uint32 _assetId,
        uint256 _fee
    ) internal pure {
        _globalInfo.protoFees = adjustUint256Array(_globalInfo.protoFees, _assetId);
        _globalInfo.protoFees[_assetId] += _fee;
    }

    /**
     * Helper to expand the chosen operator fee array (if needed) and add a given fee.
     * If "_assets" is true, use the assets fee array, otherwise use the shares fee array.
     */
    function updateOpFee(
        DataTypes.GlobalInfo memory _globalInfo,
        bool _assets,
        uint32 _idx,
        uint256 _fee
    ) internal pure {
        if (_assets) {
            _globalInfo.opFees.assets = adjustUint256Array(_globalInfo.opFees.assets, _idx);
            _globalInfo.opFees.assets[_idx] += _fee;
        } else {
            _globalInfo.opFees.shares = adjustUint256Array(_globalInfo.opFees.shares, _idx);
            _globalInfo.opFees.shares[_idx] += _fee;
        }
    }

    /**
     * Helper to expand an array of uint256, e.g. the various fee arrays in globalInfo.
     * Takes the array and the needed index and returns the unchanged array or a new expanded one.
     */
    function adjustUint256Array(uint256[] memory _array, uint32 _idx) internal pure returns (uint256[] memory) {
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
     * Helper to get the fee type and amount.
     * Returns (isCelr, fee).
     */
    function getFeeInfo(uint128 _fee) internal pure returns (bool, uint256) {
        bool isCelr = _fee & UINT128_HIBIT == UINT128_HIBIT;
        if (isCelr) {
            _fee = _fee ^ UINT128_HIBIT;
        }
        return (isCelr, uint256(_fee));
    }

    function splitUint16(uint16 _code) internal pure returns (uint8, uint8) {
        uint8 high = uint8(_code >> 8);
        uint8 low = uint8(_code);
        return (high, low);
    }

    function splitUint64(uint64 _code) internal pure returns (uint32, uint32) {
        uint32 high = uint32(_code >> 32);
        uint32 low = uint32(_code);
        return (high, low);
    }

    function splitUint128(uint128 _code) internal pure returns (uint64, uint64) {
        uint64 high = uint64(_code >> 64);
        uint64 low = uint64(_code);
        return (high, low);
    }

    function splitUint256(uint256 _code) internal pure returns (uint128, uint128) {
        uint128 high = uint128(_code >> 128);
        uint128 low = uint128(_code);
        return (high, low);
    }
}
