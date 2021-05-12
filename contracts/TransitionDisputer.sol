// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import {DataTypes as dt} from "./libraries/DataTypes.sol";
import {Transitions as tn} from "./libraries/Transitions.sol";
import "./libraries/MerkleTree.sol";
import "./TransitionEvaluator.sol";
import "./Registry.sol";

contract TransitionDisputer {
    // state root of empty strategy set and empty account set
    bytes32 public constant INIT_TRANSITION_STATE_ROOT =
        bytes32(0xcf277fb80a82478460e8988570b718f1e083ceb76f7e271a1a1497e5975f53ae);

    using SafeMath for uint256;

    TransitionEvaluator transitionEvaluator;

    constructor(TransitionEvaluator _transitionEvaluator) {
        transitionEvaluator = _transitionEvaluator;
    }

    /**********************
     * External Functions *
     **********************/

    struct disputeStateInfo {
        bytes32 preStateRoot;
        bytes32 postStateRoot;
        uint32 accountId;
        uint32 accountIdDest;
        uint32 strategyId;
    }

    /**
     * @notice Dispute a transition.
     *
     * @param _inputs The dispute input parameters.
     * @param _registry The address of the Registry contract.
     *
     * @return reason of the transition being determined as invalid
     */
    function disputeTransition(dt.DisputeInputs calldata _inputs, Registry _registry) external returns (string memory) {
        require(_inputs.accountProofs.length > 0, "At least one account proof must be given");
        if (_inputs.invalidTransitionProof.blockId == 0 && _inputs.invalidTransitionProof.index == 0) {
            require(
                _invalidInitTransition(_inputs.invalidTransitionProof, _inputs.invalidTransitionBlock),
                "no fraud detected"
            );
            return "invalid init transition";
        }

        // ------ #1: verify sequential transitions
        // First verify that the transitions are sequential and in their respective block root hashes.
        _verifySequentialTransitions(
            _inputs.prevTransitionProof,
            _inputs.invalidTransitionProof,
            _inputs.prevTransitionBlock,
            _inputs.invalidTransitionBlock
        );

        // ------ #2: decode transitions to get post- and pre-StateRoot, and ids of account(s) and strategy
        (bool ok, disputeStateInfo memory dsi) =
            _getStateRootsAndIds(_inputs.prevTransitionProof.transition, _inputs.invalidTransitionProof.transition);
        // If not success something went wrong with the decoding...
        if (!ok) {
            // revert the block if it has an incorrectly encoded transition!
            return "invalid encoding";
        }

        if ((dsi.accountId > 0) && (dsi.accountIdDest > 0)) {
            require(_inputs.accountProofs.length == 2, "Two account proofs must be given");
        } else if (dsi.accountId > 0) {
            require(_inputs.accountProofs.length == 1, "One account proof must be given");
        }

        // ------ #3: verify transition stateRoot == hash(globalInfoHash, accountStateRoot, strategyStateRoot)
        // The global info and the account and strategy stateRoots must always be given irrespective of
        // what is being disputed.
        require(
            _checkMultiTreeStateRoot(
                dsi.preStateRoot,
                keccak256(_getGlobalInfoBytes(_inputs.globalInfo)),
                _inputs.accountProofs[0].stateRoot,
                _inputs.strategyProof.stateRoot
            ),
            "Failed combined multi-tree stateRoot verification check"
        );
        for (uint256 i = 1; i < _inputs.accountProofs.length; i++) {
            require(
                _inputs.accountProofs[i].stateRoot == _inputs.accountProofs[0].stateRoot,
                "all account proof state roots not equal"
            );
        }

        // ------ #4: verify account and strategy inclusion
        if (dsi.accountId > 0) {
            for (uint256 i = 0; i < _inputs.accountProofs.length; i++) {
                _verifyProofInclusion(
                    _inputs.accountProofs[i].stateRoot,
                    keccak256(_getAccountInfoBytes(_inputs.accountProofs[i].value)),
                    _inputs.accountProofs[i].index,
                    _inputs.accountProofs[i].siblings
                );
            }
        }
        if (dsi.strategyId > 0) {
            _verifyProofInclusion(
                _inputs.strategyProof.stateRoot,
                keccak256(_getStrategyInfoBytes(_inputs.strategyProof.value)),
                _inputs.strategyProof.index,
                _inputs.strategyProof.siblings
            );
        }

        // ------ #5: verify deposit account id mapping
        uint8 transitionType = tn.extractTransitionType(_inputs.invalidTransitionProof.transition);
        if (transitionType == tn.TN_TYPE_DEPOSIT) {
            dt.DepositTransition memory transition =
                tn.decodePackedDepositTransition(_inputs.invalidTransitionProof.transition);
            if (
                _inputs.accountProofs[0].value.account == transition.account &&
                _inputs.accountProofs[0].value.accountId != dsi.accountId
            ) {
                // same account address with different id
                return "invalid account id";
            }
        }

        // ------ #6: verify transition account and strategy indexes
        if (dsi.accountId > 0) {
            require(_inputs.accountProofs[0].index == dsi.accountId, "Account index is incorrect");
            if (dsi.accountIdDest > 0) {
                require(_inputs.accountProofs[1].index == dsi.accountIdDest, "Destination account index is incorrect");
            }
        }
        if (dsi.strategyId > 0) {
            require(_inputs.strategyProof.index == dsi.strategyId, "Supplied strategy index is incorrect");
        }

        // ------ #7: evaluate transition and verify new state root
        // split function to address "stack too deep" compiler error
        return _evaluateInvalidTransition(_inputs, dsi.postStateRoot, _registry);
    }

    /*********************
     * Private Functions *
     *********************/

    /**
     * @notice Evaluate a disputed transition
     * @dev This was split from the disputeTransition function to address "stack too deep" compiler error
     *
     * @param _inputs The dispute input parameters.
     * @param _postStateRoot State root of the disputed transition.
     * @param _registry The address of the Registry contract.
     */
    function _evaluateInvalidTransition(
        dt.DisputeInputs calldata _inputs,
        bytes32 _postStateRoot,
        Registry _registry
    ) private returns (string memory) {
        // Apply the transaction and verify the state root after that.
        bool ok;
        bytes memory returnData;
        dt.AccountInfo[] memory _accountInfos = new dt.AccountInfo[](_inputs.accountProofs.length);
        for (uint256 i = 0; i < _inputs.accountProofs.length; i++) {
            _accountInfos[i] = _inputs.accountProofs[i].value;
        }

        // Make the external call
        (ok, returnData) = address(transitionEvaluator).call(
            abi.encodeWithSelector(
                transitionEvaluator.evaluateTransition.selector,
                _inputs.invalidTransitionProof.transition,
                _accountInfos,
                _inputs.strategyProof.value,
                _inputs.globalInfo,
                _registry
            )
        );
        // Check if it was successful. If not, we've got to revert.
        if (!ok) {
            return "failed to evaluate";
        }
        // It was successful so let's decode the outputs to get the new leaf nodes we'll have to insert
        bytes32[4] memory outputs = abi.decode((returnData), (bytes32[4]));

        // Check if the combined new stateRoots of account and strategy Merkle trees is incorrect.
        ok = _updateAndVerify(_postStateRoot, outputs, _inputs.accountProofs, _inputs.strategyProof);
        if (!ok) {
            // revert the block because we found an invalid post state root
            return "invalid post-state root";
        }

        revert("No fraud detected");
    }

    /**
     * @notice Get state roots, account id, and strategy id of the disputed transition.
     *
     * @param _preStateTransition transition immediately before the disputed transition
     * @param _invalidTransition the disputed transition
     */
    function _getStateRootsAndIds(bytes memory _preStateTransition, bytes memory _invalidTransition)
        private
        returns (bool, disputeStateInfo memory)
    {
        bool success;
        bytes memory returnData;
        bytes32 preStateRoot;
        bytes32 postStateRoot;
        uint32 accountId;
        uint32 accountIdDest;
        uint32 strategyId;
        disputeStateInfo memory dsi;

        // First decode the prestate root
        (success, returnData) = address(transitionEvaluator).call(
            abi.encodeWithSelector(transitionEvaluator.getTransitionStateRootAndAccessIds.selector, _preStateTransition)
        );

        // Make sure the call was successful
        require(success, "If the preStateRoot is invalid, then prove that invalid instead");
        (preStateRoot, , , ) = abi.decode((returnData), (bytes32, uint32, uint32, uint32));

        // Now that we have the prestateRoot, let's decode the postState
        (success, returnData) = address(transitionEvaluator).call(
            abi.encodeWithSelector(TransitionEvaluator.getTransitionStateRootAndAccessIds.selector, _invalidTransition)
        );

        // If the call was successful let's decode!
        if (success) {
            (postStateRoot, accountId, accountIdDest, strategyId) = abi.decode(
                (returnData),
                (bytes32, uint32, uint32, uint32)
            );
            dsi.preStateRoot = preStateRoot;
            dsi.postStateRoot = postStateRoot;
            dsi.accountId = accountId;
            dsi.accountIdDest = accountIdDest;
            dsi.strategyId = strategyId;
        }
        return (success, dsi);
    }

    /**
     * @notice Evaluate if the init transition of the first block is invalid
     *
     * @param _initTransitionProof The inclusion proof of the disputed initial transition.
     * @param _firstBlock The first rollup block
     */
    function _invalidInitTransition(dt.TransitionProof calldata _initTransitionProof, dt.Block calldata _firstBlock)
        private
        returns (bool)
    {
        require(_checkTransitionInclusion(_initTransitionProof, _firstBlock), "transition not included in block");
        (bool success, bytes memory returnData) =
            address(transitionEvaluator).call(
                abi.encodeWithSelector(
                    TransitionEvaluator.getTransitionStateRootAndAccessIds.selector,
                    _initTransitionProof.transition
                )
            );
        if (!success) {
            return true; // transition is invalid
        }
        (bytes32 postStateRoot, , ) = abi.decode((returnData), (bytes32, uint32, uint32));

        // Transition is invalid if stateRoot does not match the expected init root.
        // It's OK that other fields of the transition are incorrect.
        return postStateRoot != INIT_TRANSITION_STATE_ROOT;
    }

    /**
     * @notice Get the bytes value for this account.
     *
     * @param _accountInfo Account info
     */
    function _getAccountInfoBytes(dt.AccountInfo memory _accountInfo) private pure returns (bytes memory) {
        // If it's an empty storage slot, return 32 bytes of zeros (empty value)
        if (
            _accountInfo.account == address(0) &&
            _accountInfo.accountId == 0 &&
            _accountInfo.idleAssets.length == 0 &&
            _accountInfo.shares.length == 0 &&
            _accountInfo.pending.length == 0 &&
            _accountInfo.timestamp == 0
        ) {
            return abi.encodePacked(uint256(0));
        }
        // Here we don't use `abi.encode([struct])` because it's not clear
        // how to generate that encoding client-side.
        return
            abi.encode(
                _accountInfo.account,
                _accountInfo.accountId,
                _accountInfo.idleAssets,
                _accountInfo.shares,
                _accountInfo.pending,
                _accountInfo.timestamp
            );
    }

    /**
     * @notice Get the bytes value for this strategy.
     * @param _strategyInfo Strategy info
     */
    function _getStrategyInfoBytes(dt.StrategyInfo memory _strategyInfo) private pure returns (bytes memory) {
        // If it's an empty storage slot, return 32 bytes of zeros (empty value)
        if (
            _strategyInfo.assetId == 0 &&
            _strategyInfo.assetBalance == 0 &&
            _strategyInfo.shareSupply == 0 &&
            _strategyInfo.nextAggregateId == 0 &&
            _strategyInfo.lastExecAggregateId == 0 &&
            _strategyInfo.pending.length == 0
        ) {
            return abi.encodePacked(uint256(0));
        }
        // Here we don't use `abi.encode([struct])` because it's not clear
        // how to generate that encoding client-side.
        return
            abi.encode(
                _strategyInfo.assetId,
                _strategyInfo.assetBalance,
                _strategyInfo.shareSupply,
                _strategyInfo.nextAggregateId,
                _strategyInfo.lastExecAggregateId,
                _strategyInfo.pending
            );
    }

    /**
     * @notice Get the bytes value for this global info.
     * @param _globalInfo Global fee-tracking info
     */
    function _getGlobalInfoBytes(dt.GlobalInfo memory _globalInfo) private pure returns (bytes memory) {
        if (
            _globalInfo.protoFees.received.length == 0 &&
            _globalInfo.protoFees.pending.length == 0 &&
            _globalInfo.opFees.assets.length == 0 &&
            _globalInfo.opFees.shares.length == 0 &&
            _globalInfo.currEpoch == 0
        ) {
            return abi.encodePacked(uint256(0));
        }
        // Here we don't use `abi.encode([struct])` because it's not clear
        // how to generate that encoding client-side.
        return
            abi.encode(
                _globalInfo.protoFees.received,
                _globalInfo.protoFees.pending,
                _globalInfo.opFees.assets,
                _globalInfo.opFees.shares,
                _globalInfo.currEpoch
            );
    }

    /**
     * @notice Verifies that two transitions were included one after another.
     * @dev This is used to make sure we are comparing the correct prestate & poststate.
     */
    function _verifySequentialTransitions(
        dt.TransitionProof calldata _tp0,
        dt.TransitionProof calldata _tp1,
        dt.Block calldata _prevTransitionBlock,
        dt.Block calldata _invalidTransitionBlock
    ) private pure returns (bool) {
        // Start by checking if they are in the same block
        if (_tp0.blockId == _tp1.blockId) {
            // If the blocknumber is the same, check that tp0 precedes tp1
            require(_tp0.index + 1 == _tp1.index, "Transitions must be sequential");
            require(_tp1.index < _invalidTransitionBlock.blockSize, "_tp1 outside block range");
        } else {
            // If not in the same block, check that:
            // 0) the blocks are one after another
            require(_tp0.blockId + 1 == _tp1.blockId, "Blocks must be sequential or equal");

            // 1) the index of tp0 is the last in its block
            require(_tp0.index == _prevTransitionBlock.blockSize - 1, "_tp0 must be last in its block");

            // 2) the index of tp1 is the first in its block
            require(_tp1.index == 0, "_tp1 must be first in its block");
        }

        // Verify inclusion
        require(_checkTransitionInclusion(_tp0, _prevTransitionBlock), "_tp0 must be included in its block");
        require(_checkTransitionInclusion(_tp1, _invalidTransitionBlock), "_tp1 must be included in its block");

        return true;
    }

    /**
     * @notice Check to see if a transition is included in the block.
     */
    function _checkTransitionInclusion(dt.TransitionProof memory _tp, dt.Block memory _block)
        private
        pure
        returns (bool)
    {
        bytes32 rootHash = _block.rootHash;
        bytes32 leafHash = keccak256(_tp.transition);
        return MerkleTree.verify(rootHash, leafHash, _tp.index, _tp.siblings);
    }

    /**
     * @notice Check if the combined stateRoots of the Merkle trees matches the stateRoot.
     * @dev hash(globalInfoHash, accountStateRoot, strategyStateRoot)
     */
    function _checkMultiTreeStateRoot(
        bytes32 _stateRoot,
        bytes32 _globalInfoHash,
        bytes32 _accountStateRoot,
        bytes32 _strategyStateRoot
    ) private pure returns (bool) {
        bytes32 newStateRoot = keccak256(abi.encodePacked(_globalInfoHash, _accountStateRoot, _strategyStateRoot));
        return (_stateRoot == newStateRoot);
    }

    /**
     * @notice Check if an account or strategy proof is included in the state root.
     */
    function _verifyProofInclusion(
        bytes32 _stateRoot,
        bytes32 _leafHash,
        uint32 _index,
        bytes32[] memory _siblings
    ) private pure {
        bool ok = MerkleTree.verify(_stateRoot, _leafHash, _index, _siblings);
        require(ok, "Failed proof inclusion verification check");
    }

    /**
     * @notice Update the account, strategy, and global info Merkle trees with their new leaf nodes and check validity.
     * @dev The _leafHashes array holds: [account (src), account (dest), strategy, globalInfo].
     */
    function _updateAndVerify(
        bytes32 _stateRoot,
        bytes32[4] memory _leafHashes,
        dt.AccountProof[] memory _accountProofs,
        dt.StrategyProof memory _strategyProof
    ) private pure returns (bool) {
        if (_leafHashes[0] == bytes32(0) && _leafHashes[1] == bytes32(0)) {
            return false;
        }

        // If there is an account update, compute its new Merkle tree root.
        // If there are two account updates (i.e. transfer), compute their combined new Merkle tree root.
        bytes32 accountStateRoot = _accountProofs[0].stateRoot;
        if (_leafHashes[0] != bytes32(0)) {
            if (_leafHashes[1] != bytes32(0)) {
                accountStateRoot = MerkleTree.computeRootTwoLeaves(
                    _leafHashes[0],
                    _leafHashes[1],
                    _accountProofs[0].index,
                    _accountProofs[1].index,
                    _accountProofs[0].siblings,
                    _accountProofs[1].siblings
                );
            } else {
                accountStateRoot = MerkleTree.computeRoot(
                    _leafHashes[0],
                    _accountProofs[0].index,
                    _accountProofs[0].siblings
                );
            }
        }

        // If there is a strategy update, compute its new Merkle tree root.
        bytes32 strategyStateRoot = _strategyProof.stateRoot;
        if (_leafHashes[2] != bytes32(0)) {
            strategyStateRoot = MerkleTree.computeRoot(_leafHashes[1], _strategyProof.index, _strategyProof.siblings);
        }

        return _checkMultiTreeStateRoot(_stateRoot, _leafHashes[3], accountStateRoot, strategyStateRoot);
    }
}
