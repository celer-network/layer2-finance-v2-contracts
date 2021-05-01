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

    function decodeDepositTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.DepositTransition memory)
    {
        (uint8 transitionType, bytes32 stateRoot, address account, uint64 infoCode, uint256 amount) =
            abi.decode((_rawBytes), (uint8, bytes32, address, uint64, uint256));
        DataTypes.DepositTransition memory transition =
            DataTypes.DepositTransition(transitionType, stateRoot, account, infoCode, amount);
        return transition;
    }

    function decodeDepositInfoCode(uint64 _infoCode) internal pure returns (uint32, uint32) {
        (uint32 accountId, uint32 assetId) = splitUint64(_infoCode);
        return (accountId, assetId);
    }

    function decodeWithdrawTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.WithdrawTransition memory)
    {
        (
            uint8 transitionType,
            bytes32 stateRoot,
            address account,
            uint128 infoCode,
            uint256 amount,
            uint256 fee,
            bytes memory signature
        ) = abi.decode((_rawBytes), (uint8, bytes32, address, uint128, uint256, uint256, bytes));
        DataTypes.WithdrawTransition memory transition =
            DataTypes.WithdrawTransition(transitionType, stateRoot, account, infoCode, amount, fee, signature);
        return transition;
    }

    function decodeWithdrawInfoCode(uint128 _infoCode)
        internal
        pure
        returns (
            uint32, // accountId
            uint32, // assetId
            uint64 // timestamp
        )
    {
        (uint64 high, uint64 timestamp) = splitUint128(_infoCode);
        (uint32 accountId, uint32 assetId) = splitUint64(high);
        return (accountId, assetId, timestamp);
    }

    function decodeBuyTransition(bytes memory _rawBytes) internal pure returns (DataTypes.BuyTransition memory) {
        (
            uint8 transitionType,
            bytes32 stateRoot,
            uint128 infoCode,
            uint256 amount,
            uint256 fee,
            bytes memory signature
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint128, uint256, uint256, bytes));
        DataTypes.BuyTransition memory transition =
            DataTypes.BuyTransition(transitionType, stateRoot, infoCode, amount, fee, signature);
        return transition;
    }

    function decodeSellTransition(bytes memory _rawBytes) internal pure returns (DataTypes.SellTransition memory) {
        (
            uint8 transitionType,
            bytes32 stateRoot,
            uint128 infoCode,
            uint256 shares,
            uint256 fee,
            bytes memory signature
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint128, uint256, uint256, bytes));
        DataTypes.SellTransition memory transition =
            DataTypes.SellTransition(transitionType, stateRoot, infoCode, shares, fee, signature);
        return transition;
    }

    function decodeBuySellInfoCode(uint256 _infoCode)
        internal
        pure
        returns (
            uint32, // accountId
            uint32, // strategyId
            uint64, // timestamp
            uint128 // maxSharePrice or minSharePrice
        )
    {
        (uint128 h1, uint128 priceLimit) = splitUint256(_infoCode);
        (uint64 h2, uint64 timestamp) = splitUint128(h1);
        (uint32 accountId, uint32 strategyId) = splitUint64(h2);
        return (accountId, strategyId, timestamp, priceLimit);
    }

    function decodeTransferAssetTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.TransferAssetTransition memory)
    {
        (
            uint8 transitionType,
            bytes32 stateRoot,
            uint256 infoCode,
            uint256 amount,
            uint256 fee,
            bytes memory signature
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint256, uint256, uint256, bytes));
        DataTypes.TransferAssetTransition memory transition =
            DataTypes.TransferAssetTransition(transitionType, stateRoot, infoCode, amount, fee, signature);
        return transition;
    }

    function decodeTransferShareTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.TransferShareTransition memory)
    {
        (
            uint8 transitionType,
            bytes32 stateRoot,
            uint256 infoCode,
            uint256 shares,
            uint256 fee,
            bytes memory signature
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint256, uint256, uint256, bytes));
        DataTypes.TransferShareTransition memory transition =
            DataTypes.TransferShareTransition(transitionType, stateRoot, infoCode, shares, fee, signature);
        return transition;
    }

    function decodeTransferInfoCode(uint256 _infoCode)
        internal
        pure
        returns (
            uint32, // assetId or strategyId
            uint32, // fromAccountId
            uint32, // toAccountId
            uint64 // timestamp
        )
    {
        (uint128 high, uint128 low) = splitUint256(_infoCode);
        (uint64 acctIds, uint64 timestamp) = splitUint128(low);
        (uint32 fromAccountId, uint32 toAccountId) = splitUint64(acctIds);
        uint32 assetOrStId = uint32(high);
        return (assetOrStId, fromAccountId, toAccountId, timestamp);
    }

    function decodeSettlementTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.SettlementTransition memory)
    {
        (uint8 transitionType, bytes32 stateRoot, uint128 infoCode) =
            abi.decode((_rawBytes), (uint8, bytes32, uint128));
        DataTypes.SettlementTransition memory transition =
            DataTypes.SettlementTransition(transitionType, stateRoot, infoCode);
        return transition;
    }

    function decodeSettlementInfoCode(uint128 _infoCode)
        internal
        pure
        returns (
            uint32, // accountId
            uint32, // strategyId
            uint64 // aggregateId
        )
    {
        (uint64 high, uint64 aggregateId) = splitUint128(_infoCode);
        (uint32 accountId, uint32 strategyId) = splitUint64(high);
        return (accountId, strategyId, aggregateId);
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
