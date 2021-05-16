// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/* Internal Imports */
import {DataTypes as dt} from "./libraries/DataTypes.sol";
import {Transitions as tn} from "./libraries/Transitions.sol";
import "./libraries/ErrMsg.sol";
import "./libraries/MerkleTree.sol";
import "./Registry.sol";
import "./TransitionDisputer.sol";
import "./strategies/interfaces/IStrategy.sol";
import "./interfaces/IWETH.sol";

contract RollupChain is Ownable, Pausable {
    using SafeERC20 for IERC20;

    // All intents in a block have been executed.
    uint32 public constant BLOCK_EXEC_COUNT_DONE = 2**32 - 1;

    /* Fields */
    // The state transition disputer
    TransitionDisputer transitionDisputer;
    // Asset and strategy registry
    Registry registry;

    // All the blocks (prepared and/or executed).
    dt.Block[] public blocks;
    uint256 public countExecuted;

    // Track pending L1-initiated even roundtrip status across L1->L2->L1.
    // Each event record ID is a count++ (i.e. it's a queue).
    // - L1 event creates it in "pending" status
    // - commitBlock() moves it to "done" status
    // - fraudulent block moves it back to "pending" status
    // - executeBlock() deletes it
    enum PendingEventStatus {Pending, Done}
    struct PendingEvent {
        bytes32 ehash;
        uint64 blockId; // rollup block; "pending": baseline of censorship, "done": block holding L2 transition
        PendingEventStatus status;
    }
    struct EventQueuePointer {
        uint64 executeHead; // moves up inside blockExecute() -- lowest
        uint64 commitHead; // moves up inside blockCommit() -- intermediate
        uint64 tail; // moves up inside L1 event -- highest
    }

    // pending deposit queue
    // ehash = keccak256(abi.encodePacked(account, assetId, amount))
    mapping(uint256 => PendingEvent) public pendingDeposits;
    EventQueuePointer public depositQueuePointer;

    // strategyId -> (aggregateId -> PendingExecResult)
    // ehash = keccak256(abi.encodePacked(strategyId, aggregateId, success, sharesFromBuy, amountFromSell))
    mapping(uint32 => mapping(uint256 => PendingEvent)) public pendingExecResults;
    // strategyId -> execResultQueuePointer
    mapping(uint32 => EventQueuePointer) public execResultQueuePointers;

    // Track pending withdraws arriving from L2 then done on L1 across 2 phases.
    // A separate mapping is used for each phase:
    // (1) pendingWithdrawCommits: commitBlock() --> executeBlock(), per blockId
    // (2) pendingWithdraws: executeBlock() --> L1-withdraw, per user account address
    //
    // - commitBlock() creates pendingWithdrawCommits entries for the blockId.
    // - executeBlock() aggregates them into per-account pendingWithdraws entries and
    //   deletes the pendingWithdrawCommits entries.
    // - fraudulent block deletes the pendingWithdrawCommits during the blockId rollback.
    // - L1 withdraw() gives the funds and deletes the account's pendingWithdraws entries.
    struct PendingWithdrawCommit {
        address account;
        uint32 assetId;
        uint256 amount;
    }
    mapping(uint256 => PendingWithdrawCommit[]) public pendingWithdrawCommits;

    // Mapping of account => assetId => pendingWithdrawAmount
    mapping(address => mapping(uint32 => uint256)) public pendingWithdraws;

    // per-asset (total deposit - total withdrawal) amount
    mapping(address => uint256) public netDeposits;
    // per-asset (total deposit - total withdrawal) limit
    mapping(address => uint256) public netDepositLimits;

    uint256 public blockChallengePeriod; // delay (in # of ETH blocks) to challenge a rollup block
    uint256 public maxPriorityTxDelay; // delay (in # of rollup blocks) to reflect an L1-initiated tx in a rollup block

    address public operator;

    /* Events */
    // TODO: do we need indexed event fields?
    event RollupBlockCommitted(uint256 blockId);
    event RollupBlockExecuted(uint256 blockId, uint32 execLen, uint32 totalLen);
    event RollupBlockReverted(uint256 blockId, string reason);
    event AssetDeposited(address account, uint32 assetId, uint256 amount, uint64 depositId);
    event AssetWithdrawn(address account, uint32 assetId, uint256 amount);
    event AggregationExecuted(
        uint32 strategyId,
        uint64 aggregateId,
        bool success,
        uint256 sharesFromBuy,
        uint256 amountFromSell
    );
    event OperatorChanged(address previousOperator, address newOperator);

    constructor(
        uint256 _blockChallengePeriod,
        uint256 _maxPriorityTxDelay,
        address _transitionDisputerAddress,
        address _registryAddress,
        address _operator
    ) {
        blockChallengePeriod = _blockChallengePeriod;
        maxPriorityTxDelay = _maxPriorityTxDelay;
        transitionDisputer = TransitionDisputer(_transitionDisputerAddress);
        registry = Registry(_registryAddress);
        operator = _operator;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, ErrMsg.REQ_NOT_OPER);
        _;
    }

    fallback() external payable {}

    receive() external payable {}

    /**********************
     * External Functions *
     **********************/

    /**
     * @notice Deposits ERC20 asset.
     *
     * @param _asset The asset address;
     * @param _amount The amount;
     */
    function deposit(address _asset, uint256 _amount) external whenNotPaused {
        _deposit(_asset, _amount, msg.sender);
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @notice Deposits ETH.
     *
     * @param _amount The amount;
     * @param _weth The address for WETH.
     */
    function depositETH(address _weth, uint256 _amount) external payable whenNotPaused {
        require(msg.value == _amount, ErrMsg.REQ_BAD_AMOUNT);
        _deposit(_weth, _amount, msg.sender);
        IWETH(_weth).deposit{value: _amount}();
    }

    /**
     * @notice Deposits ERC20 asset for staking reward.
     *
     * @param _asset The asset address;
     * @param _amount The amount;
     */
    function depositReward(address _asset, uint256 _amount) external whenNotPaused {
        _deposit(_asset, _amount, address(0));
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @notice Executes pending withdraw of an asset to an account.
     *
     * @param _account The destination account.
     * @param _asset The asset address;
     */
    function withdraw(address _account, address _asset) external whenNotPaused {
        uint256 amount = _withdraw(_account, _asset);
        IERC20(_asset).safeTransfer(_account, amount);
    }

    /**
     * @notice Executes pending withdraw of ETH to an account.
     *
     * @param _account The destination account.
     * @param _weth The address for WETH.
     */
    function withdrawETH(address _account, address _weth) external whenNotPaused {
        uint256 amount = _withdraw(_account, _weth);
        IWETH(_weth).withdraw(amount);
        (bool sent, ) = _account.call{value: amount}("");
        require(sent, ErrMsg.REQ_NO_WITHDRAW);
    }

    /**
     * @notice Submit a prepared batch as a new rollup block.
     *
     * @param _blockId Rollup block id
     * @param _transitions List of layer-2 transitions
     */
    function commitBlock(uint256 _blockId, bytes[] calldata _transitions) external whenNotPaused onlyOperator {
        require(_blockId == blocks.length, ErrMsg.REQ_BAD_BLOCKID);

        bytes32[] memory leafs = new bytes32[](_transitions.length);
        for (uint256 i = 0; i < _transitions.length; i++) {
            leafs[i] = keccak256(_transitions[i]);
        }
        bytes32 root = MerkleTree.getMerkleRoot(leafs);

        // Loop over transition and handle these cases:
        // 1. deposit: update the pending deposit record
        // 2. withdraw: create a pending withdraw-commit record
        // 3. aggregate-orders: fill the "intents" array for future executeBlock()
        // 4. execution-result: update the pending execution result record
        bytes32 intentHash;
        for (uint256 i = 0; i < _transitions.length; i++) {
            uint8 tnType = tn.extractTransitionType(_transitions[i]);
            if (
                tnType == tn.TN_TYPE_BUY ||
                tnType == tn.TN_TYPE_SELL ||
                tnType == tn.TN_TYPE_XFER_ASSET ||
                tnType == tn.TN_TYPE_XFER_SHARE ||
                tnType == tn.TN_TYPE_SETTLE
            ) {
                continue;
            } else if (tnType == tn.TN_TYPE_DEPOSIT) {
                // Update the pending deposit record.
                dt.DepositTransition memory dp = tn.decodePackedDepositTransition(_transitions[i]);
                _checkPendingDeposit(dp.account, dp.assetId, dp.amount, _blockId);
            } else if (tnType == tn.TN_TYPE_WITHDRAW) {
                // Append the pending withdraw-commit record for this blockId.
                dt.WithdrawTransition memory wd = tn.decodePackedWithdrawTransition(_transitions[i]);
                pendingWithdrawCommits[_blockId].push(
                    PendingWithdrawCommit({account: wd.account, assetId: wd.assetId, amount: wd.amount - wd.fee})
                );
            } else if (tnType == tn.TN_TYPE_AGGREGATE_ORDER) {
                intentHash = keccak256(abi.encodePacked(intentHash, _transitions[i]));
            } else if (tnType == tn.TN_TYPE_EXEC_RESULT) {
                // Update the pending execution result record.
                dt.ExecutionResultTransition memory er = tn.decodePackedExecutionResultTransition(_transitions[i]);
                _checkPendingExecutionResult(er, _blockId);
            } else if (tnType == tn.TN_TYPE_WITHDRAW_PROTO_FEE) {
                dt.WithdrawProtocolFeeTransition memory wf = tn.decodeWithdrawProtocolFeeTransition(_transitions[i]);
                pendingWithdrawCommits[_blockId].push(
                    PendingWithdrawCommit({account: owner(), assetId: wf.assetId, amount: wf.amount})
                );
            } else if (tnType == tn.TN_TYPE_DEPOSIT_REWARD) {
                // Update the pending deposit record.
                dt.DepositRewardTransition memory dp = tn.decodeDepositRewardTransition(_transitions[i]);
                _checkPendingDeposit(address(0), dp.assetId, dp.amount, _blockId);
            }
        }

        dt.Block memory rollupBlock =
            dt.Block({
                rootHash: root,
                intentHash: intentHash,
                intentExecCount: 0,
                blockTime: uint64(block.number),
                blockSize: uint32(_transitions.length)
            });
        blocks.push(rollupBlock);

        emit RollupBlockCommitted(_blockId);
    }

    /**
     * @notice Execute a rollup block after it passes the challenge period.
     * @dev Note: only the "intent" transitions (AggregateOrders) are given to executeBlock() instead of
     * re-sending the whole rollup block. This includes the case of a rollup block with zero intents.
     * @dev Note: this supports partial incremental block execution using the "_execLen" parameter.
     *
     * @param _blockId Rollup block id
     * @param _intents List of AggregateOrders transitions of the rollup block
     * @param _execLen The next number of AggregateOrders transitions to execute from the full list.
     */
    function executeBlock(
        uint256 _blockId,
        bytes[] calldata _intents,
        uint32 _execLen
    ) external whenNotPaused {
        require(_blockId == countExecuted, ErrMsg.REQ_BAD_BLOCKID);
        require(blocks[_blockId].blockTime + blockChallengePeriod < block.number, ErrMsg.REQ_BAD_CHALLENGE);
        uint32 intentExecCount = blocks[_blockId].intentExecCount;

        // Validate the input intent transitions.
        bytes32 intentHash;
        if (_intents.length > 0) {
            for (uint256 i = 0; i < _intents.length; i++) {
                intentHash = keccak256(abi.encodePacked(intentHash, _intents[i]));
            }
        }
        require(intentHash == blocks[_blockId].intentHash, ErrMsg.REQ_BAD_HASH);

        uint32 newIntentExecCount = intentExecCount + _execLen;
        require(newIntentExecCount <= _intents.length, ErrMsg.REQ_BAD_LEN);

        // In the first execution of any parts of this block, handle the pending deposit & withdraw records.
        if (intentExecCount == 0) {
            _cleanupPendingDeposits(_blockId);
            _cleanupPendingWithdrawCommits(_blockId);
        }

        // Decode the intent transitions and execute the strategy updates for the requested incremental batch.
        for (uint256 i = intentExecCount; i < newIntentExecCount; i++) {
            dt.AggregateOrdersTransition memory aggregation = tn.decodePackedAggregateOrdersTransition(_intents[i]);
            _executeAggregation(aggregation, _blockId);
        }

        if (newIntentExecCount == _intents.length) {
            blocks[_blockId].intentExecCount = BLOCK_EXEC_COUNT_DONE;
            countExecuted++;
        } else {
            blocks[_blockId].intentExecCount = newIntentExecCount;
        }
        emit RollupBlockExecuted(_blockId, newIntentExecCount, uint32(_intents.length));
    }

    /**
     * @notice Dispute a transition in a block.
     * @dev Provide the transition proofs of the previous (valid) transition and the disputed transition,
     * the account proof(s), the strategy proof, the staking pool proof, and the global info. The account proof(s),
     * strategy proof, staking pool proof and global info are always needed even if the disputed transition only updates
     * an account (or two) or only updates the strategy because the transition stateRoot is computed as:
     *
     * stateRoot = hash(accountStateRoot, strategyStateRoot, stakingPoolStateRoot, globalInfoHash)
     *
     * Thus all 4 components of the hash are needed to validate the input data.
     * If the transition is invalid, prune the chain from that invalid block.
     *
     * @param _prevTransitionProof The inclusion proof of the transition immediately before the fraudulent transition.
     * @param _invalidTransitionProof The inclusion proof of the fraudulent transition.
     * @param _accountProofs The inclusion proofs of one or two accounts involved.
     * @param _strategyProof The inclusion proof of the strategy involved.
     * @param _stakingPoolProof The inclusion proof of the staking pool involved.
     * @param _globalInfo The global info.
     */
    function disputeTransition(
        dt.TransitionProof calldata _prevTransitionProof,
        dt.TransitionProof calldata _invalidTransitionProof,
        dt.AccountProof[] calldata _accountProofs,
        dt.StrategyProof calldata _strategyProof,
        dt.StakingPoolProof calldata _stakingPoolProof,
        dt.GlobalInfo calldata _globalInfo
    ) external {
        dt.Block memory prevTransitionBlock = blocks[_prevTransitionProof.blockId];
        dt.Block memory invalidTransitionBlock = blocks[_invalidTransitionProof.blockId];
        require(invalidTransitionBlock.blockTime + blockChallengePeriod > block.number, ErrMsg.REQ_BAD_CHALLENGE);

        bool success;
        bytes memory returnData;
        (success, returnData) = address(transitionDisputer).call(
            abi.encodeWithSelector(
                transitionDisputer.disputeTransition.selector,
                _prevTransitionProof,
                _invalidTransitionProof,
                _accountProofs,
                _strategyProof,
                _stakingPoolProof,
                _globalInfo,
                prevTransitionBlock,
                invalidTransitionBlock
            )
        );

        if (success) {
            string memory reason = abi.decode((returnData), (string));
            _revertBlock(_invalidTransitionProof.blockId, reason);
        } else {
            revert("Failed to dispute");
        }
    }

    /**
     * @notice Dispute if operator failed to reflect an L1-initiated priority tx
     * in a rollup block within the maxPriorityTxDelay
     */
    function disputePriorityTxDelay() external {
        if (blocks.length > 0) {
            uint256 currentBlockId = blocks.length - 1;
            if (depositQueuePointer.commitHead < depositQueuePointer.tail) {
                if (currentBlockId - pendingDeposits[depositQueuePointer.commitHead].blockId > maxPriorityTxDelay) {
                    _pause();
                    return;
                }
            }
        }
        revert("Not exceed max priority tx delay");
    }

    /**
     * @notice Called by the owner to pause contract
     * @dev emergency use only
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Called by the owner to unpause contract
     * @dev emergency use only
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Owner drains one type of tokens when the contract is paused
     * @dev emergency use only
     *
     * @param _asset drained asset address
     * @param _amount drained asset amount
     */
    function drainToken(address _asset, uint256 _amount) external whenPaused onlyOwner {
        IERC20(_asset).safeTransfer(msg.sender, _amount);
    }

    /**
     * @notice Owner drains ETH when the contract is paused
     * @dev This is for emergency situations.
     *
     * @param _amount drained ETH amount
     */
    function drainETH(uint256 _amount) external whenPaused onlyOwner {
        (bool sent, ) = msg.sender.call{value: _amount}("");
        require(sent, ErrMsg.REQ_NO_DRAIN);
    }

    /**
     * @notice Called by the owner to set blockChallengePeriod
     * @param _blockChallengePeriod delay (in # of ETH blocks) to challenge a rollup block
     */
    function setBlockChallengePeriod(uint256 _blockChallengePeriod) external onlyOwner {
        blockChallengePeriod = _blockChallengePeriod;
    }

    /**
     * @notice Called by the owner to set maxPriorityTxDelay
     * @param _maxPriorityTxDelay delay (in # of rollup blocks) to reflect an L1-initiated tx in a rollup block
     */
    function setMaxPriorityTxDelay(uint256 _maxPriorityTxDelay) external onlyOwner {
        maxPriorityTxDelay = _maxPriorityTxDelay;
    }

    /**
     * @notice Called by the owner to set operator account address
     * @param _operator operator's ETH address
     */
    function setOperator(address _operator) external onlyOwner {
        emit OperatorChanged(operator, _operator);
        operator = _operator;
    }

    /**
     * @notice Called by the owner to set net deposit limit
     * @param _asset asset token address
     * @param _limit asset net deposit limit amount
     */
    function setNetDepositLimit(address _asset, uint256 _limit) external onlyOwner {
        uint32 assetId = registry.assetAddressToIndex(_asset);
        require(assetId != 0, ErrMsg.REQ_BAD_ASSET);
        netDepositLimits[_asset] = _limit;
    }

    /**
     * @notice Get count of rollup blocks.
     * @return count of rollup blocks
     */
    function getCountBlocks() public view returns (uint256) {
        return blocks.length;
    }

    /*********************
     * Private Functions *
     *********************/

    /**
     * @notice internal deposit processing without actual token transfer.
     *
     * @param _asset The asset token address.
     * @param _amount The asset token amount.
     * @param _account The account who owns the deposit (zero for reward).
     */
    function _deposit(
        address _asset,
        uint256 _amount,
        address _account
    ) private {
        uint32 assetId = registry.assetAddressToIndex(_asset);
        require(assetId > 0, ErrMsg.REQ_BAD_ASSET);

        uint256 netDeposit = netDeposits[_asset] + _amount;
        require(netDeposit <= netDepositLimits[_asset], ErrMsg.REQ_OVER_LIMIT);
        netDeposits[_asset] = netDeposit;

        // Add a pending deposit record.
        uint64 depositId = depositQueuePointer.tail++;
        bytes32 ehash = keccak256(abi.encodePacked(_account, assetId, _amount));
        pendingDeposits[depositId] = PendingEvent({
            ehash: ehash,
            blockId: uint64(blocks.length), // "pending": baseline of censorship delay
            status: PendingEventStatus.Pending
        });

        emit AssetDeposited(_account, assetId, _amount, depositId);
    }

    /**
     * @notice internal withdrawal processing without actual token transfer.
     *
     * @param _account The destination account.
     * @param _asset The asset token address.
     * @return amount to withdraw
     */
    function _withdraw(address _account, address _asset) private returns (uint256) {
        uint32 assetId = registry.assetAddressToIndex(_asset);
        require(assetId > 0, ErrMsg.REQ_BAD_ASSET);

        uint256 amount = pendingWithdraws[_account][assetId];
        require(amount > 0, ErrMsg.REQ_BAD_AMOUNT);

        if (netDeposits[_asset] < amount) {
            netDeposits[_asset] = 0;
        } else {
            netDeposits[_asset] -= amount;
        }
        pendingWithdraws[_account][assetId] = 0;

        emit AssetWithdrawn(_account, assetId, amount);
        return amount;
    }

    /**
     * @notice Check and update the pending deposit record.
     * @param _account The deposit account address.
     * @param _assetId The deposit asset Id.
     * @param _amount The deposit amount.
     * @param _blockId Commit block Id.
     */
    function _checkPendingDeposit(
        address _account,
        uint32 _assetId,
        uint256 _amount,
        uint256 _blockId
    ) private {
        EventQueuePointer memory queuePointer = depositQueuePointer;
        uint64 depositId = queuePointer.commitHead;
        require(depositId < queuePointer.tail, ErrMsg.REQ_BAD_DEP_TN);

        bytes32 ehash = keccak256(abi.encodePacked(_account, _assetId, _amount));
        require(pendingDeposits[depositId].ehash == ehash, ErrMsg.REQ_BAD_HASH);

        pendingDeposits[depositId].status = PendingEventStatus.Done;
        pendingDeposits[depositId].blockId = uint64(_blockId); // "done": block holding the transition
        queuePointer.commitHead++;
        depositQueuePointer = queuePointer;
    }

    /**
     * @notice Check and update the pending executionResult record.
     * @param _er The executionResult transition.
     * @param _blockId Commit block Id.
     */
    function _checkPendingExecutionResult(dt.ExecutionResultTransition memory _er, uint256 _blockId) private {
        EventQueuePointer memory queuePointer = execResultQueuePointers[_er.strategyId];
        uint64 aggregateId = queuePointer.commitHead;
        require(aggregateId < queuePointer.tail, ErrMsg.REQ_BAD_EXECRES_TN);

        bytes32 ehash =
            keccak256(
                abi.encodePacked(_er.strategyId, _er.aggregateId, _er.success, _er.sharesFromBuy, _er.amountFromSell)
            );
        require(pendingExecResults[_er.strategyId][aggregateId].ehash == ehash, ErrMsg.REQ_BAD_HASH);

        pendingExecResults[_er.strategyId][aggregateId].status = PendingEventStatus.Done;
        pendingExecResults[_er.strategyId][aggregateId].blockId = uint64(_blockId); // "done": block holding the transition
        queuePointer.commitHead++;
        execResultQueuePointers[_er.strategyId] = queuePointer;
    }

    /**
     * @notice execute aggregated order.
     * @param _aggregation The AggregateOrders transition.
     * @param _blockId Executed block Id.
     */
    function _executeAggregation(dt.AggregateOrdersTransition memory _aggregation, uint256 _blockId) private {
        uint32 strategyId = _aggregation.strategyId;
        address strategyAddr = registry.strategyIndexToAddress(strategyId);
        require(strategyAddr != address(0), ErrMsg.REQ_BAD_ST);
        // TODO: reset allowance to zero after strategy interaction?
        IERC20(strategyAddr).safeIncreaseAllowance(strategyAddr, _aggregation.buyAmount);
        (bool success, bytes memory returnData) =
            strategyAddr.call(
                abi.encodeWithSelector(
                    IStrategy.aggregateOrders.selector,
                    _aggregation.buyAmount,
                    _aggregation.sellShares,
                    _aggregation.minSharesFromBuy,
                    _aggregation.minAmountFromSell
                )
            );
        uint256 sharesFromBuy;
        uint256 amountFromSell;
        if (success) {
            (sharesFromBuy, amountFromSell) = abi.decode((returnData), (uint256, uint256));
        }

        EventQueuePointer memory queuePointer = execResultQueuePointers[strategyId];
        uint64 aggregateId = queuePointer.tail++;
        bytes32 ehash = keccak256(abi.encodePacked(strategyId, aggregateId, success, sharesFromBuy, amountFromSell));
        pendingExecResults[strategyId][aggregateId] = PendingEvent({
            ehash: ehash,
            blockId: uint64(blocks.length), // "pending": baseline of censorship delay
            status: PendingEventStatus.Pending
        });
        emit AggregationExecuted(strategyId, aggregateId, success, sharesFromBuy, amountFromSell);

        // Delete pending execution result finalized by this or previous block.
        while (queuePointer.executeHead < queuePointer.commitHead) {
            PendingEvent memory pend = pendingExecResults[strategyId][queuePointer.executeHead];
            if (pend.status != PendingEventStatus.Done || pend.blockId > _blockId) {
                break;
            }
            delete pendingExecResults[strategyId][queuePointer.executeHead];
            queuePointer.executeHead++;
        }
        execResultQueuePointers[strategyId] = queuePointer;
    }

    /**
     * @notice Delete pending deposits finalized by this or previous block.
     * @param _blockId Executed block Id.
     */
    function _cleanupPendingDeposits(uint256 _blockId) private {
        EventQueuePointer memory queuePointer = depositQueuePointer;
        while (queuePointer.executeHead < queuePointer.commitHead) {
            PendingEvent memory pend = pendingDeposits[queuePointer.executeHead];
            if (pend.status != PendingEventStatus.Done || pend.blockId > _blockId) {
                break;
            }
            delete pendingDeposits[queuePointer.executeHead];
            queuePointer.executeHead++;
        }
        depositQueuePointer = queuePointer;
    }

    /**
     * @notice Aggregate the pending withdraw-commit records for this blockId into the final
     *         pending withdraw records per account (for later L1 withdraw), and delete them.
     * @param _blockId Executed block Id.
     */
    function _cleanupPendingWithdrawCommits(uint256 _blockId) private {
        for (uint256 i = 0; i < pendingWithdrawCommits[_blockId].length; i++) {
            PendingWithdrawCommit memory pwc = pendingWithdrawCommits[_blockId][i];
            // Find and increment this account's assetId total amount
            pendingWithdraws[pwc.account][pwc.assetId] += pwc.amount;
        }
        delete pendingWithdrawCommits[_blockId];
    }

    /**
     * @notice Revert rollup block on dispute success
     *
     * @param _blockId Rollup block id
     * @param _reason Revert reason
     */
    function _revertBlock(uint256 _blockId, string memory _reason) private {
        // pause contract
        _pause();

        // revert blocks and pending states
        while (blocks.length > _blockId) {
            pendingWithdrawCommits[blocks.length - 1];
            blocks.pop();
        }
        bool first;
        for (uint64 i = depositQueuePointer.executeHead; i < depositQueuePointer.tail; i++) {
            if (pendingDeposits[i].blockId >= _blockId) {
                if (!first) {
                    depositQueuePointer.commitHead = i;
                    first = true;
                }
                pendingDeposits[i].blockId = uint64(_blockId);
                pendingDeposits[i].status = PendingEventStatus.Pending;
            }
        }

        emit RollupBlockReverted(_blockId, _reason);
    }
}
