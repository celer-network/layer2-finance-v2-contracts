// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;
pragma experimental ABIEncoderV2;

import "../libraries/DataTypes.sol";

library Transitions {
    // Transition Types
    uint8 public constant TRANSITION_TYPE_INVALID = 0;
    uint8 public constant TRANSITION_TYPE_INIT = 1;
    uint8 public constant TRANSITION_TYPE_DEPOSIT = 2;
    uint8 public constant TRANSITION_TYPE_WITHDRAW = 3;
    uint8 public constant TRANSITION_TYPE_BUY = 4;
    uint8 public constant TRANSITION_TYPE_SELL = 5;
    uint8 public constant TRANSITION_TYPE_XFER_ASSET = 6;
    uint8 public constant TRANSITION_TYPE_XFER_SHARE = 7;
    uint8 public constant TRANSITION_TYPE_AGGREGATE_ORDER = 8;
    uint8 public constant TRANSITION_TYPE_EXEC_RESULT = 9;
    uint8 public constant TRANSITION_TYPE_SETTLE = 10;

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
        (uint8 transitionType, bytes32 stateRoot, address account, uint32 accountId, uint32 assetId, uint256 amount) =
            abi.decode((_rawBytes), (uint8, bytes32, address, uint32, uint32, uint256));
        DataTypes.DepositTransition memory transition =
            DataTypes.DepositTransition(transitionType, stateRoot, account, accountId, assetId, amount);
        return transition;
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
            uint32 accountId,
            uint32 assetId,
            uint256 amount,
            uint256 fee,
            uint64 timestamp,
            bytes memory signature
        ) = abi.decode((_rawBytes), (uint8, bytes32, address, uint32, uint32, uint256, uint256, uint64, bytes));
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
                signature
            );
        return transition;
    }

    function decodeBuyTransition(bytes memory _rawBytes) internal pure returns (DataTypes.BuyTransition memory) {
        (
            uint8 transitionType,
            bytes32 stateRoot,
            uint32 accountId,
            uint32 strategyId,
            uint256 amount,
            uint256 maxSharePrice,
            uint256 fee,
            uint64 timestamp,
            bytes memory signature
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint32, uint32, uint256, uint256, uint256, uint64, bytes));
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
                signature
            );
        return transition;
    }

    function decodeSellTransition(bytes memory _rawBytes) internal pure returns (DataTypes.SellTransition memory) {
        (
            uint8 transitionType,
            bytes32 stateRoot,
            uint32 accountId,
            uint32 strategyId,
            uint256 shares,
            uint256 minSharePrice,
            uint256 fee,
            uint64 timestamp,
            bytes memory signature
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint32, uint32, uint256, uint256, uint256, uint64, bytes));
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
                signature
            );
        return transition;
    }

    function decodeTransferAssetTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.TransferAssetTransition memory)
    {
        (
            uint8 transitionType,
            bytes32 stateRoot,
            uint32 fromAccountId,
            uint32 toAccountId,
            uint32 assetId,
            uint256 amount,
            uint256 fee,
            uint64 timestamp,
            bytes memory signature
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint32, uint32, uint32, uint256, uint256, uint64, bytes));
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
                signature
            );
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
            uint32 fromAccountId,
            uint32 toAccountId,
            uint32 strategyId,
            uint256 shares,
            uint256 fee,
            uint64 timestamp,
            bytes memory signature
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint32, uint32, uint32, uint256, uint256, uint64, bytes));
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
                signature
            );
        return transition;
    }

    function decodeSettlementTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.SettlementTransition memory)
    {
        (
            uint8 transitionType, 
            bytes32 stateRoot, 
            uint32 strategyId,
            uint64 aggregateId,
            uint32 accountId
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint32, uint64, uint32));
        DataTypes.SettlementTransition memory transition =
            DataTypes.SettlementTransition(transitionType, stateRoot, strategyId, aggregateId, accountId);
        return transition;
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
            uint64 aggregateId,
            uint256 buyAmount,
            uint256 sellShares,
            uint256 minSharesFromBuy,
            uint256 minAmountFromSell
        ) = abi.decode((_rawBytes), (uint8, bytes32, uint32, uint64, uint256, uint256, uint256, uint256));
        DataTypes.AggregateOrdersTransition memory transition =
            DataTypes.AggregateOrdersTransition(
                transitionType,
                stateRoot,
                strategyId,
                aggregateId,
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
}
