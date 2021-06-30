// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";

/* Internal Imports */
import {DataTypes as dt} from "./libraries/DataTypes.sol";
import {Transitions as tn} from "./libraries/Transitions.sol";
import "./libraries/ErrMsg.sol";

contract PriorityQueues is Ownable {
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
    // ehash = keccak256(abi.encodePacked(strategyId, aggregateId, success, sharesFromBuy, amountFromSell))
    mapping(uint32 => mapping(uint256 => PendingEvent)) public pendingExecResults;
    // strategyId -> execResultQueuePointer
    mapping(uint32 => EventQueuePointer) public execResultQueuePointers;

    // group fields to avoid "stack too deep" error
    struct ExecResultInfo {
        uint32 strategyId;
        bool success;
        uint256 sharesFromBuy;
        uint256 amountFromSell;
        uint256 blockLen;
        uint256 blockId;
    }

    struct PendingEpochUpdate {
        uint64 epoch;
        uint64 blockId; // rollup block; "pending": baseline of censorship, "done": block holding L2 transition
        PendingEventStatus status;
    }
    mapping(uint256 => PendingEpochUpdate) public pendingEpochUpdates;
    EventQueuePointer public epochQueuePointer;

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
     * @notice Delete pending queue events finalized by this or previous block.
     * @param _blockId Executed block Id.
     */
    function cleanupPendingQueue(uint256 _blockId) external onlyController {
        // cleanup deposit queue
        EventQueuePointer memory dQueuePointer = depositQueuePointer;
        while (dQueuePointer.executeHead < dQueuePointer.commitHead) {
            PendingEvent memory pend = pendingDeposits[dQueuePointer.executeHead];
            if (pend.status != PendingEventStatus.Done || pend.blockId > _blockId) {
                break;
            }
            delete pendingDeposits[dQueuePointer.executeHead];
            dQueuePointer.executeHead++;
        }
        depositQueuePointer = dQueuePointer;

        // cleanup epoch queue
        EventQueuePointer memory eQueuePointer = epochQueuePointer;
        while (eQueuePointer.executeHead < eQueuePointer.commitHead) {
            PendingEpochUpdate memory pend = pendingEpochUpdates[eQueuePointer.executeHead];
            if (pend.status != PendingEventStatus.Done || pend.blockId > _blockId) {
                break;
            }
            delete pendingEpochUpdates[eQueuePointer.executeHead];
            eQueuePointer.executeHead++;
        }
        epochQueuePointer = eQueuePointer;
    }

    /**
     * @notice Check and update the pending executionResult record.
     * @param _tnBytes The packetExecutionResult transition bytes.
     * @param _blockId Commit block Id.
     */
    function checkPendingExecutionResult(bytes memory _tnBytes, uint256 _blockId) external onlyController {
        dt.ExecutionResultTransition memory er = tn.decodePackedExecutionResultTransition(_tnBytes);
        EventQueuePointer memory queuePointer = execResultQueuePointers[er.strategyId];
        uint64 aggregateId = queuePointer.commitHead;
        require(aggregateId < queuePointer.tail, ErrMsg.REQ_BAD_EXECRES_TN);

        bytes32 ehash = keccak256(
            abi.encodePacked(
                er.strategyId,
                er.aggregateId,
                er.success,
                er.sharesFromBuy,
                er.amountFromSell
            )
        );
        require(pendingExecResults[er.strategyId][aggregateId].ehash == ehash, ErrMsg.REQ_BAD_HASH);

        pendingExecResults[er.strategyId][aggregateId].status = PendingEventStatus.Done;
        pendingExecResults[er.strategyId][aggregateId].blockId = uint64(_blockId); // "done": block holding the transition
        queuePointer.commitHead++;
        execResultQueuePointers[er.strategyId] = queuePointer;
    }

    /**
     * @notice Add pending execution result record.
     * @return aggregate Id
     */
    function addPendingExecutionResult(ExecResultInfo calldata _er) external onlyController returns (uint64) {
        EventQueuePointer memory queuePointer = execResultQueuePointers[_er.strategyId];
        uint64 aggregateId = queuePointer.tail++;
        bytes32 ehash = keccak256(
            abi.encodePacked(_er.strategyId, aggregateId, _er.success, _er.sharesFromBuy, _er.amountFromSell)
        );
        pendingExecResults[_er.strategyId][aggregateId] = PendingEvent({
            ehash: ehash,
            blockId: uint64(_er.blockLen) - 1, // "pending": baseline of censorship delay
            status: PendingEventStatus.Pending
        });

        // Delete pending execution result finalized by this or previous block.
        while (queuePointer.executeHead < queuePointer.commitHead) {
            PendingEvent memory pend = pendingExecResults[_er.strategyId][queuePointer.executeHead];
            if (pend.status != PendingEventStatus.Done || pend.blockId > _er.blockId) {
                break;
            }
            delete pendingExecResults[_er.strategyId][queuePointer.executeHead];
            queuePointer.executeHead++;
        }
        execResultQueuePointers[_er.strategyId] = queuePointer;
        return aggregateId;
    }

    /**
     * @notice add pending epoch update
     * @param _epoch epoch value
     * @param _blockLen number of committed blocks
     * @return epoch id
     */
    function addPendingEpoch(uint64 _epoch, uint256 _blockLen) external onlyController returns (uint64) {
        uint64 epochId = epochQueuePointer.tail++;
        pendingEpochUpdates[epochId] = PendingEpochUpdate({
            epoch: _epoch,
            blockId: uint64(_blockLen), // "pending": baseline of censorship delay
            status: PendingEventStatus.Pending
        });
        return epochId;
    }

    /**
     * @notice Check and update the pending epoch update record.
     * @param _epoch The epoch value.
     * @param _blockId Commit block Id.
     */
    function checkPendingEpochUpdate(uint64 _epoch, uint256 _blockId) external onlyController {
        EventQueuePointer memory queuePointer = epochQueuePointer;
        uint64 epochId = queuePointer.commitHead;
        require(epochId < queuePointer.tail, ErrMsg.REQ_BAD_EPOCH_TN);

        require(pendingEpochUpdates[epochId].epoch == _epoch, ErrMsg.REQ_BAD_EPOCH);
        pendingEpochUpdates[epochId].status = PendingEventStatus.Done;
        pendingEpochUpdates[epochId].blockId = uint64(_blockId); // "done": block holding the transition
        queuePointer.commitHead++;
        epochQueuePointer = queuePointer;
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

            EventQueuePointer memory dQueuePointer = depositQueuePointer;
            if (dQueuePointer.commitHead < dQueuePointer.tail) {
                if (currentBlockId - pendingDeposits[dQueuePointer.commitHead].blockId > _maxPriorityTxDelay) {
                    return true;
                }
            }

            EventQueuePointer memory eQueuePointer = epochQueuePointer;
            if (eQueuePointer.commitHead < eQueuePointer.tail) {
                if (currentBlockId - pendingEpochUpdates[eQueuePointer.commitHead].blockId > _maxPriorityTxDelay) {
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
