// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;
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
    uint8 public constant TN_TYPE_WITHDRAW_PROTO_FEE = 11;
    uint8 public constant TN_TYPE_XFER_OP_FEE = 12;

    // Liquidity Mining
    uint8 public constant TN_TYPE_STAKE = 13;
    uint8 public constant TN_TYPE_UNSTAKE = 14;
    uint8 public constant TN_TYPE_UPDATE_POOL_INFO = 15;

    function extractTransitionType(bytes memory _bytes) internal pure returns (uint8) {
        uint8 transitionType;
        assembly {
            transitionType := mload(add(_bytes, 0x20))
        }
        return transitionType;
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
        (uint256 infoCode, bytes32 stateRoot, address account, uint256 amount, uint128 fee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, address, uint256, uint128, bytes32, bytes32));
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
        (uint128 infoCode, bytes32 stateRoot, uint256 sharesFromBuy, uint256 amountFromSell) =
            abi.decode((_rawBytes), (uint128, bytes32, uint256, uint256));
        (uint64 aggregateId, uint32 strategyId, bool success, uint8 transitionType) =
            decodeExecutionResultInfoCode(infoCode);
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

    function decodeExecutionResultInfoCode(uint128 _infoCode)
        internal
        pure
        returns (
            uint64, // aggregateId
            uint32, // strategyId
            bool, // success
            uint8 // transitionType
        )
    {
        (uint64 aggregateId, uint64 low) = splitUint128(_infoCode);
        (uint32 strategyId, uint32 low2) = splitUint64(low);
        uint8 transitionType = uint8(low2);
        bool success = uint8(low2 >> 8) == 1;
        return (aggregateId, strategyId, success, transitionType);
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
