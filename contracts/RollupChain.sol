// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/* Internal Imports */
import {DataTypes as dt} from "./libraries/DataTypes.sol";
import {Transitions as tn} from "./libraries/Transitions.sol";
import "./libraries/MerkleTree.sol";
import "./Registry.sol";
import "./strategies/interfaces/IStrategy.sol";
import "./interfaces/IWETH.sol";

/*
import "./TransitionDisputer.sol";
*/

contract RollupChain is Ownable, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // All intents in a block have been executed.
    uint32 public constant BLOCK_EXEC_COUNT_DONE = 2**32 - 1;

    /* Fields */
    // The state transition disputer
    // TransitionDisputer transitionDisputer;
    // Asset and strategy registry
    Registry registry;

    // All the blocks (prepared and/or executed).
    dt.Block[] public blocks;
    uint256 public countExecuted = 0;

    // Track pending L1-initiated even roundtrip status across L1->L2->L1.
    // Each event record ID is a count++ (i.e. it's a queue).
    // - L1 event creates it in "pending" status
    // - commitBlock() moves it to "done" status
    // - fraudulent block moves it back to "pending" status
    // - executeBlock() deletes it
    enum PendingEventStatus {Init, Pending, Done}
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
        // transitionDisputer = TransitionDisputer(_transitionDisputerAddress);
        registry = Registry(_registryAddress);
        operator = _operator;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "caller is not operator");
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
        _deposit(_asset, _amount);
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @notice Deposits ETH.
     *
     * @param _amount The amount;
     * @param _weth The address for WETH.
     */
    function depositETH(address _weth, uint256 _amount) external payable whenNotPaused {
        require(msg.value == _amount, "ETH amount mismatch");
        _deposit(_weth, _amount);
        IWETH(_weth).deposit{value: _amount}();
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
        require(sent, "Failed to withdraw ETH");
    }

    /**
     * @notice Submit a prepared batch as a new rollup block.
     *
     * @param _blockId Rollup block id
     * @param _transitions List of layer-2 transitions
     */
    function commitBlock(uint256 _blockId, bytes[] calldata _transitions) external whenNotPaused onlyOperator {
        require(_blockId == blocks.length, "Wrong block ID");

        bytes32[] memory leafs = new bytes32[](_transitions.length);
        for (uint256 i = 0; i < _transitions.length; i++) {
            leafs[i] = keccak256(_transitions[i]);
        }
        bytes32 root = MerkleTree.getMerkleRoot(leafs);

        // Loop over transition and handle these cases:
        // 1- deposit: update the pending deposit record
        // 2- withdraw: create a pending withdraw-commit record
        // 3- aggregate order: fill the "intents" array for future executeBlock()
        // 4- execution result: update the pending execution result record

        uint256[] memory intentIndexes = new uint256[](_transitions.length);
        uint32 numIntents = 0;

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
                _checkPendingDeposit(dp, _blockId);
            } else if (tnType == tn.TN_TYPE_WITHDRAW) {
                // Append the pending withdraw-commit record for this blockId.
                dt.WithdrawTransition memory wd = tn.decodePackedWithdrawTransition(_transitions[i]);
                pendingWithdrawCommits[_blockId].push(
                    PendingWithdrawCommit({account: wd.account, assetId: wd.assetId, amount: wd.amount - wd.fee})
                );
            } else if (tnType == tn.TN_TYPE_AGGREGATE_ORDER) {
                intentIndexes[numIntents++] = i;
            } else if (tnType == tn.TN_TYPE_EXEC_RESULT) {
                // Update the pending execution result record.
                dt.ExecutionResultTransition memory er = tn.decodePackedExecutionResultTransition(_transitions[i]);
                _checkPendingExecutionResult(er, _blockId);
            }
        }

        // Compute the intent hash.
        bytes32 intentHash = bytes32(0);
        if (numIntents > 0) {
            bytes32[] memory intents = new bytes32[](numIntents);
            for (uint256 i = 0; i < numIntents; i++) {
                intents[i] = keccak256(_transitions[intentIndexes[i]]);
            }
            intentHash = keccak256(abi.encodePacked(intents));
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
     * @dev Note: only the "intent" transitions (commitment sync) are given to executeBlock() instead of
     * re-sending the whole rollup block. This includes the case of a rollup block with zero intents.
     * @dev Note: this supports partial incremental block execution using the "_execLen" parameter.
     *
     * @param _blockId Rollup block id
     * @param _intents List of CommitmentSync transitions of the rollup block
     * @param _execLen The next number of CommitmentSync transitions to execute from the full list.
     */
    function executeBlock(
        uint256 _blockId,
        bytes[] calldata _intents,
        uint32 _execLen
    ) external whenNotPaused {
        require(_blockId == countExecuted, "Wrong block ID");
        require(_blockId < blocks.length, "No blocks pending execution");
        require(blocks[_blockId].blockTime + blockChallengePeriod < block.number, "Block still in challenge period");
        uint32 intentExecCount = blocks[_blockId].intentExecCount;
        require(intentExecCount != BLOCK_EXEC_COUNT_DONE, "Block already executed");

        // Validate the input intent transitions.
        bytes32 intentHash = bytes32(0);
        if (_intents.length > 0) {
            bytes32[] memory hashes = new bytes32[](_intents.length);
            for (uint256 i = 0; i < _intents.length; i++) {
                hashes[i] = keccak256(_intents[i]);
            }
            intentHash = keccak256(abi.encodePacked(hashes));
        }

        require(intentHash == blocks[_blockId].intentHash, "Invalid block intent transitions");
        uint32 newIntentExecCount = intentExecCount + _execLen;
        require(newIntentExecCount <= _intents.length, "Invalid _execLen value");

        // In the first execution of any parts of this block, handle the pending deposit & withdraw records.
        if (intentExecCount == 0) {
            _cleanupPendingDeposits(_blockId);
            _cleanupPendingWithdrawCommits(_blockId);
        }

        // Decode the intent transitions and execute the strategy updates for the requested incremental batch.
        for (uint256 i = intentExecCount; i < newIntentExecCount; i++) {
            dt.AggregateOrdersTransition memory order = tn.decodePackedAggregateOrdersTransition(_intents[i]);
            _executeAggregationOrder(order, _blockId);
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
     * @notice Dispute if operator failed to reflect an L1-initiated priority tx
     * in a rollup block within the maxPriorityTxDelay
     */
    function disputePriorityTxDelay() external {
        if (blocks.length > 0) {
            uint256 currentBlockId = blocks.length - 1;
            if (depositQueuePointer.commitHead < depositQueuePointer.tail) {
                if (currentBlockId.sub(pendingDeposits[depositQueuePointer.commitHead].blockId) > maxPriorityTxDelay) {
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
        require(sent, "Failed to drain ETH");
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
        require(assetId != 0, "Unknown asset");
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
     */
    function _deposit(address _asset, uint256 _amount) private {
        address account = msg.sender;
        uint32 assetId = registry.assetAddressToIndex(_asset);

        require(assetId != 0, "Unknown asset");

        uint256 netDeposit = netDeposits[_asset].add(_amount);
        require(netDeposit <= netDepositLimits[_asset], "net deposit exceeds limit");
        netDeposits[_asset] = netDeposit;

        // Add a pending deposit record.
        uint64 depositId = depositQueuePointer.tail++;
        bytes32 ehash = keccak256(abi.encodePacked(account, assetId, _amount));
        pendingDeposits[depositId] = PendingEvent({
            ehash: ehash,
            blockId: uint64(blocks.length), // "pending": baseline of censorship delay
            status: PendingEventStatus.Pending
        });

        emit AssetDeposited(account, assetId, _amount, depositId);
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
        require(assetId > 0, "Asset not registered");

        uint256 amount = pendingWithdraws[_account][assetId];
        require(amount > 0, "Nothing to withdraw");

        if (netDeposits[_asset] < amount) {
            netDeposits[_asset] = 0;
        } else {
            netDeposits[_asset] = netDeposits[_asset].sub(amount);
        }
        pendingWithdraws[_account][assetId] = 0;

        emit AssetWithdrawn(_account, assetId, amount);
        return amount;
    }

    /**
     * @notice Check and update the pending deposit record.
     * @param _dp The deposit transition.
     * @param _blockId Commit block Id.
     */
    function _checkPendingDeposit(dt.DepositTransition memory _dp, uint256 _blockId) private {
        EventQueuePointer memory queuePointer = depositQueuePointer;
        uint64 depositId = queuePointer.commitHead;
        require(depositId < queuePointer.tail, "invalid deposit transition, no pending deposit");

        bytes32 ehash = keccak256(abi.encodePacked(_dp.account, _dp.assetId, _dp.amount));
        require(pendingDeposits[depositId].ehash == ehash, "invalid deposit transition, mismatch or wrong ordering");

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
        require(aggregateId < queuePointer.tail, "invalid executionResult transition, no pending execution result");

        bytes32 ehash =
            keccak256(
                abi.encodePacked(_er.strategyId, _er.aggregateId, _er.success, _er.sharesFromBuy, _er.amountFromSell)
            );
        require(
            pendingExecResults[_er.strategyId][aggregateId].ehash == ehash,
            "invalid executionResult transition, mismatch or wrong ordering"
        );

        pendingExecResults[_er.strategyId][aggregateId].status = PendingEventStatus.Done;
        pendingExecResults[_er.strategyId][aggregateId].blockId = uint64(_blockId); // "done": block holding the transition
        queuePointer.commitHead++;
        execResultQueuePointers[_er.strategyId] = queuePointer;
    }

    /**
     * @notice execute aggregation order.
     * @param _order The aggregationOrder transition.
     * @param _blockId Executed block Id.
     */
    function _executeAggregationOrder(dt.AggregateOrdersTransition memory _order, uint256 _blockId) private {
        address stAddr = registry.strategyIndexToAddress(_order.strategyId);
        require(stAddr != address(0), "Unknown strategy ID");
        IStrategy strategy = IStrategy(stAddr);
        // TODO: reset allowance to zero after strategy interaction?
        IERC20(strategy.getAssetAddress()).safeIncreaseAllowance(stAddr, _order.buyAmount);
        (bool success, bytes memory returnData) =
            stAddr.call(
                abi.encodeWithSelector(
                    IStrategy.aggregateOrder.selector,
                    _order.buyAmount,
                    _order.sellShares,
                    _order.minSharesFromBuy,
                    _order.minAmountFromSell
                )
            );
        uint256 sharesFromBuy;
        uint256 amountFromSell;
        if (success) {
            (sharesFromBuy, amountFromSell) = abi.decode((returnData), (uint256, uint256));
        }

        uint32 strategyId = _order.strategyId;
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
