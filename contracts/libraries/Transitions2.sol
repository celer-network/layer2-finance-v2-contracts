// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;
pragma experimental ABIEncoderV2;

import "../libraries/DataTypes.sol";
import {Transitions as tn} from "../libraries/Transitions.sol";

library Transitions2 {
    // fee encoding mask
    uint128 public constant UINT128_HIBIT = 2**127;

    function decodeInitTransition(bytes memory _rawBytes) internal pure returns (DataTypes.InitTransition memory) {
        (uint8 transitionType, bytes32 stateRoot) = abi.decode((_rawBytes), (uint8, bytes32));
        DataTypes.InitTransition memory transition = DataTypes.InitTransition(transitionType, stateRoot);
        return transition;
    }

    function decodePackedBuyTransition(bytes memory _rawBytes) internal pure returns (DataTypes.BuyTransition memory) {
        (uint256 infoCode, bytes32 stateRoot, uint256 amount, uint256 fee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, uint256, bytes32, bytes32));
        (uint32 accountId, uint32 strategyId, uint64 timestamp, uint128 maxSharePrice, uint8 v, uint8 transitionType) =
            decodeBuySellInfoCode(infoCode);
        (uint128 reducedFee, uint128 signedFee) = tn.splitUint256(fee);
        DataTypes.BuyTransition memory transition =
            DataTypes.BuyTransition(
                transitionType,
                stateRoot,
                accountId,
                strategyId,
                amount,
                maxSharePrice,
                signedFee,
                reducedFee,
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
        (uint128 reducedFee, uint128 signedFee) = tn.splitUint256(fee);
        DataTypes.SellTransition memory transition =
            DataTypes.SellTransition(
                transitionType,
                stateRoot,
                accountId,
                strategyId,
                shares,
                minSharePrice,
                signedFee,
                reducedFee,
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
        (uint128 h1, uint128 low) = tn.splitUint256(_infoCode);
        (uint64 h2, uint64 timestamp) = tn.splitUint128(h1);
        (uint32 accountId, uint32 strategyId) = tn.splitUint64(h2);
        uint128 sharePrice = uint128(low >> 16);
        (uint8 v, uint8 transitionType) = tn.splitUint16(uint16(low));
        return (accountId, strategyId, timestamp, sharePrice, v, transitionType);
    }

    function decodePackedTransferAssetTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.TransferAssetTransition memory)
    {
        (uint256 infoCode, bytes32 stateRoot, uint256 amount, uint128 fee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, uint128, bytes32, bytes32));
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
        (uint256 infoCode, bytes32 stateRoot, uint256 shares, uint128 fee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, uint128, bytes32, bytes32));
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
        (uint128 high, uint128 low) = tn.splitUint256(_infoCode);
        (uint64 astId, uint64 acctIds) = tn.splitUint128(high);
        (uint32 fromAccountId, uint32 toAccountId) = tn.splitUint64(acctIds);
        (uint64 timestamp, uint64 vt) = tn.splitUint128(low);
        (uint8 v, uint8 transitionType) = tn.splitUint16(uint16(vt));
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
        (uint128 high, uint128 low) = tn.splitUint256(_infoCode);
        (uint64 ids, uint64 aggregateId) = tn.splitUint128(high);
        (uint32 accountId, uint32 strategyId) = tn.splitUint64(ids);
        uint8 transitionType = uint8(low);
        return (accountId, strategyId, aggregateId, transitionType);
    }

    function decodePackedStakeTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.StakeTransition memory)
    {
        (uint256 infoCode, bytes32 stateRoot, uint256 shares, uint128 fee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, uint128, bytes32, bytes32));
        (uint32 poolId, uint32 accountId, uint64 timestamp, uint8 v, uint8 transitionType) =
            decodeStakingInfoCode(infoCode);
        DataTypes.StakeTransition memory transition =
            DataTypes.StakeTransition(transitionType, stateRoot, poolId, accountId, shares, fee, timestamp, r, s, v);
        return transition;
    }

    function decodePackedUnstakeTransition(bytes memory _rawBytes)
        internal
        pure
        returns (DataTypes.UnstakeTransition memory)
    {
        (uint256 infoCode, bytes32 stateRoot, uint256 shares, uint128 fee, bytes32 r, bytes32 s) =
            abi.decode((_rawBytes), (uint256, bytes32, uint256, uint128, bytes32, bytes32));
        (uint32 poolId, uint32 accountId, uint64 timestamp, uint8 v, uint8 transitionType) =
            decodeStakingInfoCode(infoCode);
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
        (uint128 high, uint128 low) = tn.splitUint256(_infoCode);
        (, uint64 poolIdAccountId) = tn.splitUint128(high);
        (uint32 poolId, uint32 accountId) = tn.splitUint64(poolIdAccountId);
        (uint64 timestamp, uint64 vt) = tn.splitUint128(low);
        (uint8 v, uint8 transitionType) = tn.splitUint16(uint16(vt));
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
     * Helper to expand the chosen protocol fee array (if needed) and add or subtract a given fee.
     * If "_pending" is true, use the pending fee array, otherwise use the received fee array.
     */
    function updateProtoFee(
        DataTypes.GlobalInfo memory _globalInfo,
        bool _add,
        bool _pending,
        uint32 _assetId,
        uint256 _fee
    ) internal pure {
        if (_pending) {
            _globalInfo.protoFees.pending = adjustUint256Array(_globalInfo.protoFees.pending, _assetId);
            if (_add) {
                _globalInfo.protoFees.pending[_assetId] += _fee;
            } else {
                _globalInfo.protoFees.pending[_assetId] -= _fee;
            }
        } else {
            _globalInfo.protoFees.received = adjustUint256Array(_globalInfo.protoFees.received, _assetId);
            if (_add) {
                _globalInfo.protoFees.received[_assetId] += _fee;
            } else {
                _globalInfo.protoFees.received[_assetId] -= _fee;
            }
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
     * Helper to get the fee type and handle any fee reduction.
     * Returns (isCelr, fee).
     */
    function getFeeInfo(uint128 _fee, uint128 _reducedFee) internal pure returns (bool, uint256) {
        bool isCelr = _fee & UINT128_HIBIT == UINT128_HIBIT;
        if (_reducedFee & UINT128_HIBIT == UINT128_HIBIT) {
            _reducedFee = _reducedFee ^ UINT128_HIBIT;
            if (_reducedFee < _fee) {
                _fee = _reducedFee;
            }
        }
        return (isCelr, uint256(_fee));
    }
}
