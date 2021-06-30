// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

library DataTypes {
    struct Block {
        bytes32 rootHash;
        bytes32 intentHash; // hash of L2-to-L1 aggregate-orders transitions
        uint32 intentExecCount; // count of intents executed so far (MAX_UINT32 == all done)
        uint32 blockSize; // number of transitions in the block
        uint64 blockTime; // blockNum when this rollup block is committed
    }

    struct InitTransition {
        uint8 transitionType;
        bytes32 stateRoot;
    }

    // decoded from calldata submitted as PackedDepositTransition
    struct DepositTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        address account;
        uint32 accountId;
        uint32 assetId;
        uint256 amount;
    }

    // decoded from calldata submitted as PackedWithdrawTransition
    struct WithdrawTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        address account; // target address for "pending withdraw" handling
        uint32 accountId;
        uint32 assetId;
        uint256 amount;
        uint128 fee;
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes32 r; // signature r
        bytes32 s; // signature s
        uint8 v; // signature v
    }

    // decoded from calldata submitted as PackedBuySellTransition
    struct BuyTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 accountId;
        uint32 strategyId;
        uint256 amount;
        uint128 maxSharePrice;
        uint128 fee; // user signed [1bit-type]:[127bit-amt]
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes32 r; // signature r
        bytes32 s; // signature s
        uint8 v; // signature v
    }

    // decoded from calldata submitted as PackedBuySellTransition
    struct SellTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 accountId;
        uint32 strategyId;
        uint256 shares;
        uint128 minSharePrice;
        uint128 fee; // user signed [1bit-type]:[127bit-amt]
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes32 r; // signature r
        bytes32 s; // signature s
        uint8 v; // signature v
    }

    // decoded from calldata submitted as PackedTransferTransition
    struct TransferAssetTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 fromAccountId;
        uint32 toAccountId;
        address toAccount;
        uint32 assetId;
        uint256 amount;
        uint128 fee; // user signed [1bit-type]:[127bit-amt]
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes32 r; // signature r
        bytes32 s; // signature s
        uint8 v; // signature v
    }

    // decoded from calldata submitted as PackedTransferTransition
    struct TransferShareTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 fromAccountId;
        uint32 toAccountId;
        address toAccount;
        uint32 strategyId;
        uint256 shares;
        uint128 fee; // user signed [1bit-type]:[127bit-amt]
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes32 r; // signature r
        bytes32 s; // signature s
        uint8 v; // signature v
    }

    // decoded from calldata submitted as PackedSettlementTransition
    struct SettlementTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 strategyId;
        uint64 aggregateId;
        uint32 accountId;
        uint128 celrRefund; // fee refund in celr
        uint128 assetRefund; // fee refund in asset
    }

    // decoded from calldata submitted as PackedAggregateOrdersTransition
    struct AggregateOrdersTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 strategyId;
        uint256 buyAmount;
        uint256 sellShares;
        uint256 minSharesFromBuy;
        uint256 minAmountFromSell;
    }

    // decoded from calldata submitted as PackedExecutionResultTransition
    struct ExecutionResultTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 strategyId;
        uint64 aggregateId;
        bool success;
        uint256 sharesFromBuy;
        uint256 amountFromSell;
    }

    // decoded from calldata submitted as PackedStakingTransition
    struct StakeTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 poolId;
        uint32 accountId;
        uint256 shares;
        uint128 fee; // user signed [1bit-type]:[127bit-amt]
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes32 r; // signature r
        bytes32 s; // signature s
        uint8 v; // signature v
    }

    // decoded from calldata submitted as PackedStakingTransition
    struct UnstakeTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 accountId;
        uint32 poolId;
        uint256 shares;
        uint128 fee; // user signed [1bit-type]:[127bit-amt]
        uint64 timestamp; // Unix epoch (msec, UTC)
        bytes32 r; // signature r
        bytes32 s; // signature s
        uint8 v; // signature v
    }

    struct AddPoolTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 poolId;
        uint32 strategyId;
        uint32[] rewardAssetIds;
        uint256[] rewardPerEpoch;
        uint256 stakeAdjustmentFactor;
        uint64 startEpoch;
    }

    struct UpdatePoolTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 poolId;
        uint256[] rewardPerEpoch;
    }

    struct DepositRewardTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 assetId;
        uint256 amount;
    }

    struct WithdrawProtocolFeeTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 assetId;
        uint256 amount;
    }

    struct TransferOperatorFeeTransition {
        uint8 transitionType;
        bytes32 stateRoot;
        uint32 accountId; // destination account Id
    }

    struct UpdateEpochTransition {
        uint8 transitionType;
        uint64 epoch;
    }

    struct OperatorFees {
        uint256[] assets; // assetId -> collected asset fees. CELR has assetId 1.
        uint256[] shares; // strategyId -> collected strategy share fees.
    }

    struct GlobalInfo {
        uint256[] protoFees; // assetId -> collected asset fees owned by contract owner (governance multi-sig account)
        OperatorFees opFees; // fee owned by operator
        uint64 currEpoch; // liquidity mining epoch
        uint256[] rewards; // assetId -> available reward amount
    }

    // Pending account actions (buy/sell) per account, strategy, aggregateId.
    // The array of PendingAccountInfo structs is sorted by ascending aggregateId, and holes are ok.
    struct PendingAccountInfo {
        uint64 aggregateId;
        uint256 buyAmount;
        uint256 sellShares;
        uint256 buyFees; // fees (in asset) for buy transitions
        uint256 sellFees; // fees (in asset) for sell transitions
        uint256 celrFees; // fees (in celr) for buy and sell transitions
    }

    struct AccountInfo {
        address account;
        uint32 accountId; // mapping only on L2 must be part of stateRoot
        uint256[] idleAssets; // indexed by assetId
        uint256[] shares; // indexed by strategyId
        PendingAccountInfo[][] pending; // indexed by [strategyId][i], i.e. array of pending records per strategy
        uint256[] stakedShares; // poolID -> share balance
        uint256[] stakes; // poolID -> Adjusted stake
        uint256[][] rewardDebts; // poolID -> rewardTokenID -> Reward debt
        uint64 timestamp; // Unix epoch (msec, UTC)
    }

    // Pending strategy actions per strategy, aggregateId.
    // The array of PendingStrategyInfo structs is sorted by ascending aggregateId, and holes are ok.
    struct PendingStrategyInfo {
        uint64 aggregateId;
        uint128 maxSharePriceForBuy; // decimal in 1e18
        uint128 minSharePriceForSell; // decimal in 1e18
        uint256 buyAmount;
        uint256 sellShares;
        uint256 sharesFromBuy;
        uint256 amountFromSell;
        uint256 unsettledBuyAmount;
        uint256 unsettledSellShares;
        bool executionSucceed;
    }

    struct StrategyInfo {
        uint32 assetId;
        uint256 assetBalance;
        uint256 shareSupply;
        uint64 nextAggregateId;
        uint64 lastExecAggregateId;
        PendingStrategyInfo[] pending; // array of pending records
    }

    struct StakingPoolInfo {
        uint32 strategyId;
        uint32[] rewardAssetIds; // reward asset index -> asset ID
        uint256[] rewardPerEpoch; // reward asset index -> reward per epoch, must be limited in length
        uint256 totalShares;
        uint256 totalStakes;
        uint256[] accumulatedRewardPerUnit; // reward asset index -> Accumulated reward per unit of stake, times 1e12 to avoid very small numbers
        uint64 lastRewardEpoch; // Last epoch that reward distribution occurs. Initially set by an AddPoolTransition
        uint256 stakeAdjustmentFactor; // A fraction to dilute whales. i.e. (0, 1) * 1e12
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

    struct StakingPoolProof {
        bytes32 stateRoot; // for the staking pool Merkle tree
        StakingPoolInfo value;
        uint32 index;
        bytes32[] siblings;
    }

    struct EvaluateInfos {
        AccountInfo[] accountInfos;
        StrategyInfo strategyInfo;
        StakingPoolInfo stakingPoolInfo;
        GlobalInfo globalInfo;
    }

    // ------------------ packed transitions submitted as calldata ------------------

    // calldata size: 4 x 32 bytes
    struct PackedDepositTransition {
        /* infoCode packing:
        96:127 [uint32 accountId]
        64:95  [uint32 assetId]
        8:63   [0]
        0:7    [uint8 tntype] */
        uint128 infoCode;
        bytes32 stateRoot;
        address account;
        uint256 amount;
    }

    // calldata size: 7 x 32 bytes
    struct PackedWithdrawTransition {
        /* infoCode packing:
        224:255 [uint32 accountId]
        192:223 [uint32 assetId]
        128:191 [uint64 timestamp]
        16:127  [0]
        8:15    [uint8 sig-v]
        0:7     [uint8 tntype] */
        uint256 infoCode;
        bytes32 stateRoot;
        address account;
        uint256 amtfee; // [128bit-amount]:[128bit-fee] uint128 is large enough
        bytes32 r;
        bytes32 s;
    }

    // calldata size: 6 x 32 bytes
    struct PackedBuySellTransition {
        /* infoCode packing:
        224:255 [uint32 accountId]
        192:223 [uint32 strategyId]
        128:191 [uint64 timestamp]
        16:127  [uint112 minSharePrice or maxSharePrice] // 112 bits are enough
        8:15    [uint8 sig-v]
        0:7     [uint8 tntype] */
        uint256 infoCode;
        bytes32 stateRoot;
        uint256 amtfee; // [128bit-share/amount]:[128bit-fee] uint128 is large enough
        bytes32 r;
        bytes32 s;
    }

    // calldata size: 6 x 32 bytes
    struct PackedTransferTransition {
        /* infoCode packing:
        224:255 [0]
        192:223 [uint32 assetId or strategyId]
        160:191 [uint32 fromAccountId]
        128:159 [uint32 toAccountId]
        64:127  [uint64 timestamp]
        16:63   [0]
        8:15    [uint8 sig-v]
        0:7     [uint8 tntype] */
        uint256 infoCode;
        bytes32 stateRoot;
        address toAccount;
        uint256 amtfee; // [128bit-share/amount]:[128bit-fee] uint128 is large enough
        bytes32 r;
        bytes32 s;
    }

    // calldata size: 2 x 32 bytes
    struct PackedSettlementTransition {
        /* infoCode packing:
        224:255 [uint32 accountId]
        192:223 [uint32 strategyId]
        160:191 [uint32 aggregateId] // uint32 is enough for per-strategy aggregateId
        104:159 [uint56 celrRefund] // celr refund in 9 decimal
        8:103   [uint96 assetRefund] // asseet refund
        0:7     [uint8 tntype] */
        uint256 infoCode;
        bytes32 stateRoot;
    }

    // calldata size: 6 x 32 bytes
    struct PackedAggregateOrdersTransition {
        /* infoCode packing:
        32:63  [uint32 strategyId]
        8:31   [0]
        0:7    [uint8 tntype] */
        uint64 infoCode;
        bytes32 stateRoot;
        uint256 buyAmount;
        uint256 sellShares;
        uint256 minSharesFromBuy;
        uint256 minAmountFromSell;
    }

    // calldata size: 4 x 32 bytes
    struct PackedExecutionResultTransition {
        /* infoCode packing:
        64:127  [uint64 aggregateId]
        32:63   [uint32 strategyId]
        9:31    [0]
        8:8     [bool success]
        0:7     [uint8 tntype] */
        uint128 infoCode;
        bytes32 stateRoot;
        uint256 sharesFromBuy;
        uint256 amountFromSell;
    }

    // calldata size: 6 x 32 bytes
    struct PackedStakingTransition {
        /* infoCode packing:
        192:255 [0]
        160:191 [uint32 poolId]
        128:159 [uint32 accountId]
        64:127  [uint64 timestamp]
        16:63   [0]
        8:15    [uint8 sig-v]
        0:7     [uint8 tntype] */
        uint256 infoCode;
        bytes32 stateRoot;
        uint256 sharefee; // [128bit-share]:[128bit-fee] uint128 is large enough
        bytes32 r;
        bytes32 s;
    }
}
