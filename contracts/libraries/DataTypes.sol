// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;

library DataTypes {
    struct Block {
        bytes32 rootHash;
        bytes32 intentHash; // hash of L2-to-L1 commitment sync transitions
        uint32 intentExecCount; // count of intents executed so far (MAX_UINT32 == all done)
        uint32 blockSize; // number of transitions in the block
        uint64 blockTime; // blockNum when this rollup block is committed
    }

    struct InitTransition {
        uint8 transitionType;
        bytes32 stateRoot;
    }

    struct DepositTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        address account; // must provide L1 address for "pending deposit" handling
        uint32 accountId; // needed for transition evaluation in case of dispute
        uint32 assetId;
        uint256 amount;
    }

    struct WithdrawTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        address account; // must provide L1 target address for "pending withdraw" handling
        uint32 accountId;
        uint32 assetId;
        uint256 amount;
        uint256 maxFee; // in units of asset; signed by the user
        uint256 fee; // in units of asset; actual fee payment
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes signature;
    }

    struct BuyTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 accountId;
        uint32 strategyId;
        uint256 amount;
        uint256 minShares;
        uint256 maxFee; // in units of asset; signed by the user
        uint256 fee; // in units of asset; actual fee payment
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes signature;
    }

    struct SellTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 accountId;
        uint32 strategyId;
        uint256 shares;
        uint256 minAmount;
        uint256 maxFee; // in units of share; signed by the user
        uint256 fee; // in units of share; actual fee payment
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes signature;
    }

    struct AssetTransferTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 fromAccountId;
        uint32 toAccountId;
        uint32 assetId;
        uint256 amount;
        uint256 maxFee; // in units of asset; signed by the user
        uint256 fee; // in units of asset; actual fee payment
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes signature;
    }

    struct ShareTransferTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 fromAccountId;
        uint32 toAccountId;
        uint32 strategyId;
        uint256 shares;
        uint256 maxFee; // in units of share; signed by the user
        uint256 fee; // in units of share; actual fee payment
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes signature;
    }

    struct SettlementTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        int64 rubId;
        uint32 accountId;
        uint32 strategyId;
    }

    struct CommitmentSyncTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 strategyId;
        uint256 buyAmount;
        uint256 sellShares;
        uint256 minSharesFromBuy;
        uint256 minAmountFromSell;
    }

    struct ExecutionResultTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        int64 rubId;
        uint32 strategyId;
        uint256 sharesFromBuy;
        uint256 amountFromSell;
    }

    // Pending account actions (buy/sell) per account, strategy, rubId.
    // The array of PendingAccountInfo structs is sorted by ascending rubId, and holes are ok.
    struct PendingAccountInfo {
        int64 rubId;
        uint256 buyAmount;
        uint256 buyFees;
        uint256 sellShares;
        uint256 sellFees;
    }

    struct AccountInfo {
        address account;
        uint32 accountId; // mapping only on L2 must be part of stateRoot
        uint256[] idleAssets; // indexed by assetId
        uint256[] shares; // indexed by strategyId
        PendingAccountInfo[][] pending; // indexed by [strategyId][i], i.e. array of pending records per strategy
        uint64 timestamp; // Unix epoch (msec, UTC)
    }

    // Pending strategy actions per strategy, rubId.
    // The array of PendingStrategyInfo structs is sorted by ascending rubId, and holes are ok.
    struct PendingStrategyInfo {
        int64 rubId;
        uint256 projectedSharePrice; // TODO: do we still need this?
        uint256 buyAmount;
        uint256 sellShares;
        uint256 unsettledSharesFromBuy;
        uint256 unsettledAmountFromSell;
    }

    struct StrategyInfo {
        uint32 assetId;
        uint64 lastExecRubId;
        uint256 assetBalance;
        uint256 shareSupply;
        PendingStrategyInfo[] pending; // array of pending records per strategy
    }

    struct TransitionProof {
        bytes transition;
        uint256 blockId;
        uint32 index;
        bytes32[] siblings;
    }

    // Even when the disputed transition only affects an account without a strategy or only
    // affects a strategy without an account, both AccountProof and StrategyProof must be sent
    // to at least give the root hashes of the two separate Merkle trees (account and strategy).
    // Each transition stateRoot = hash(accountStateRoot, strategyStateRoot).
    struct AccountProof {
        bytes32 stateRoot; // for the account Merkle tree
        AccountInfo value;
        uint32 index;
        bytes32[] siblings;
    }

    struct StrategyProof {
        bytes32 stateRoot; // for the strategy Merkle tree
        StrategyInfo value;
        uint32 index;
        bytes32[] siblings;
    }
}
