// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;
pragma experimental ABIEncoderV2;

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
        (uint256 infoCode, bytes32 stateRoot, address account, uint256 amount, uint256 fee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, address, uint256, uint256, bytes32, bytes32));
        (uint32 accountId, uint32 assetId, uint64 timestamp, uint8 v, uint8 transitionType) =
            decodeWithdrawInfoCode(infoCode);
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
        (uint256 infoCode, bytes32 stateRoot, uint256 amount, uint256 fee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, uint256, bytes32, bytes32));
        (uint32 accountId, uint32 strategyId, uint64 timestamp, uint128 maxSharePrice, uint8 v, uint8 transitionType) =
            decodeBuySellInfoCode(infoCode);
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
        (uint256 infoCode, bytes32 stateRoot, uint256 shares, uint256 fee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, uint256, bytes32, bytes32));
        (uint32 accountId, uint32 strategyId, uint64 timestamp, uint128 minSharePrice, uint8 v, uint8 transitionType) =
            decodeBuySellInfoCode(infoCode);
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
        (uint256 infoCode, bytes32 stateRoot, uint256 amount, uint256 fee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, uint256, bytes32, bytes32));
        (uint32 assetId, uint32 fromAccountId, uint32 toAccountId, uint64 timestamp, uint8 v, uint8 transitionType) =
            decodeTransferInfoCode(infoCode);
        DataTypes.TransferAssetTransition memory transition =
            DataTypes.TransferAssetTransition(
                transitionType,
                stateRoot,
                fromAccountId,
                toAccountId,
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
        (uint256 infoCode, bytes32 stateRoot, uint256 shares, uint256 fee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, uint256, bytes32, bytes32));
        (uint32 strategyId, uint32 fromAccountId, uint32 toAccountId, uint64 timestamp, uint8 v, uint8 transitionType) =
            decodeTransferInfoCode(infoCode);
        DataTypes.TransferShareTransition memory transition =
            DataTypes.TransferShareTransition(
                transitionType,
                stateRoot,
                fromAccountId,
                toAccountId,
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
        (uint32 accountId, uint32 strategyId, uint64 aggregateId, uint8 transitionType) =
            decodeSettlementInfoCode(infoCode);
        DataTypes.SettlementTransition memory transition =
            DataTypes.SettlementTransition(transitionType, stateRoot, strategyId, aggregateId, accountId);
        return transition;
    }

    function decodeSettlementInfoCode(uint256 _infoCode)
        internal
        pure
        returns (
            uint32, // accountId
            uint32, // strategyId
            uint64, // aggregateId
            uint8 // transitionType
        )
    {
        (uint128 high, uint128 low) = splitUint256(_infoCode);
        (uint64 ids, uint64 aggregateId) = splitUint128(high);
        (uint32 accountId, uint32 strategyId) = splitUint64(ids);
        uint8 transitionType = uint8(low);
        return (accountId, strategyId, aggregateId, transitionType);
    }

    function decodeAggregateOrdersTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.AggregateOrdersTransition memory)
    {
        (
            uint8 transitionType,
            bytes32 stateRoot,
            uint32 strategyId,
            uint256 buyAmount,
            uint256 sellShares,
            uint256 minSharesFromBuy,
            uint256 minAmountFromSell
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint32, uint256, uint256, uint256, uint256));
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

    function decodeExecutionResultTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.ExecutionResultTransition memory)
    {
        (
            uint8 transitionType,
            bytes32 stateRoot,
            uint32 strategyId,
            uint64 aggregateId,
            bool success,
            uint256 sharesFromBuy,
            uint256 amountFromSell
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint32, uint64, bool, uint256, uint256));
        DataTypes.ExecutionResultTransition memory transition =
            DataTypes.ExecutionResultTransition(
                transitionType,
                stateRoot,
                strategyId,
                aggregateId,
                success,
                sharesFromBuy,
                amountFromSell
            );
        return transition;
    }

    function splitUint16(uint16 _code) internal pure returns (uint8, uint8) {
        uint8 high = uint8(_code >> 5);
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
