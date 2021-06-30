// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./libraries/ErrMsg.sol";

contract PendingQueues is Ownable {
    address public controller;

    // Track pending L1-initiated even roundtrip status across L1->L2->L1.
    // Each event record ID is a count++ (i.e. it's a queue).
    // - L1 event creates it in "pending" status
    // - commitBlock() moves it to "done" status
    // - fraudulent block moves it back to "pending" status
    // - executeBlock() deletes it
    enum PendingEventStatus {
        Pending,
        Done
    }
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
    // ehash = keccak256(abi.encodePacked(strategyId, aggregateId, success, sharesFromBuy, amountFromSell, currEpoch))
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

    modifier onlyController() {
        require(msg.sender == controller, "caller is not controller");
        _;
    }

    function setController(address _controller) external onlyOwner {
        require(controller == address(0), "controller already set");
        controller = _controller;
    }

    /**
     * @notice Add pending deposit record.
     * @param _account The deposit account address.
     * @param _assetId The deposit asset Id.
     * @param _amount The deposit amount.
     * @param _blockId Commit block Id.
     * @return deposit Id
     */
    function addPendingDeposit(
        address _account,
        uint32 _assetId,
        uint256 _amount,
        uint256 _blockId
    ) external onlyController returns (uint64) {
        // Add a pending deposit record.
        uint64 depositId = depositQueuePointer.tail++;
        bytes32 ehash = keccak256(abi.encodePacked(_account, _assetId, _amount));
        pendingDeposits[depositId] = PendingEvent({
            ehash: ehash,
            blockId: uint64(_blockId), // "pending": baseline of censorship delay
            status: PendingEventStatus.Pending
        });
        return depositId;
    }

    /**
     * @notice Check and update the pending deposit record.
     * @param _account The deposit account address.
     * @param _assetId The deposit asset Id.
     * @param _amount The deposit amount.
     * @param _blockId Commit block Id.
     */
    function checkPendingDeposit(
        address _account,
        uint32 _assetId,
        uint256 _amount,
        uint256 _blockId
    ) external onlyController {
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
     * @notice Delete pending deposits finalized by this or previous block.
     * @param _blockId Executed block Id.
     */
    function cleanupPendingDeposits(uint256 _blockId) external onlyController {
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
     * @notice Dispute if operator failed to reflect an L1-initiated priority tx
     * in a rollup block within the maxPriorityTxDelay
     * @param _blockLen number of committed blocks.
     * @param _maxPriorityTxDelay maximm allowed delay for priority tx
     */
    function disputePriorityTxDelay(uint256 _blockLen, uint256 _maxPriorityTxDelay)
        external
        view
        onlyController
        returns (bool)
    {
        if (_blockLen > 0) {
            uint256 currentBlockId = _blockLen - 1;
            EventQueuePointer memory queuePointer = depositQueuePointer;
            if (queuePointer.commitHead < queuePointer.tail) {
                if (currentBlockId - pendingDeposits[queuePointer.commitHead].blockId > _maxPriorityTxDelay) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * @notice Revert rollup block on dispute success
     * @param _blockId Rollup block Id.
     */
    function revertBlock(uint256 _blockId) external onlyController {
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
    }
}
