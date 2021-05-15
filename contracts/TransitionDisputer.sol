// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;
pragma abicoder v2;

import {DataTypes as dt} from "./libraries/DataTypes.sol";
import {Transitions as tn} from "./libraries/Transitions.sol";
import "./libraries/ErrMsg.sol";
import "./libraries/MerkleTree.sol";
import "./TransitionEvaluator.sol";
import "./Registry.sol";

contract TransitionDisputer {
    // state root of empty account, strategy, or staking pool set
    bytes32 public constant INIT_TRANSITION_STATE_ROOT =
        bytes32(0xcf277fb80a82478460e8988570b718f1e083ceb76f7e271a1a1497e5975f53ae);

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
        uint32 stakingPoolId;
    }

    /**
     * @notice Dispute a transition.
     *
     * @param _prevTransitionProof The inclusion proof of the transition immediately before the fraudulent transition.
     * @param _invalidTransitionProof The inclusion proof of the fraudulent transition.
     * @param _accountProofs The inclusion proofs of one or two accounts involved.
     * @param _strategyProof The inclusion proof of the strategy involved.
     * @param _stakingPoolProof The inclusion proof of the staking pool involved.
     * @param _globalInfo The global info.
     * @param _prevTransitionBlock The previous transition block
     * @param _invalidTransitionBlock The invalid transition block
     * @param _registry The address of the Registry contract.
     *
     * @return reason of the transition being determined as invalid
     */
    function disputeTransition(
        dt.TransitionProof calldata _prevTransitionProof,
        dt.TransitionProof calldata _invalidTransitionProof,
        dt.AccountProof[] calldata _accountProofs,
        dt.StrategyProof calldata _strategyProof,
        dt.StakingPoolProof calldata _stakingPoolProof,
        dt.GlobalInfo calldata _globalInfo,
        dt.Block calldata _prevTransitionBlock,
        dt.Block calldata _invalidTransitionBlock,
        Registry _registry
    ) external returns (string memory) {
        require(_accountProofs.length > 0, ErrMsg.REQ_ONE_ACCT);
        if (_invalidTransitionProof.blockId == 0 && _invalidTransitionProof.index == 0) {
            require(_invalidInitTransition(_invalidTransitionProof, _invalidTransitionBlock), ErrMsg.REQ_NO_FRAUD);
            return "bad init tn";
        }

        // ------ #1: verify sequential transitions
        // First verify that the transitions are sequential and in their respective block root hashes.
        _verifySequentialTransitions(
            _prevTransitionProof,
            _invalidTransitionProof,
            _prevTransitionBlock,
            _invalidTransitionBlock
        );

        // ------ #2: decode transitions to get post- and pre-StateRoot, and ids of account(s) and strategy
        (bool ok, disputeStateInfo memory dsi) =
            _getStateRootsAndIds(_prevTransitionProof.transition, _invalidTransitionProof.transition);
        // If not success something went wrong with the decoding...
        if (!ok) {
            // revert the block if it has an incorrectly encoded transition!
            return "bad encoding";
        }

        if ((dsi.accountId > 0) && (dsi.accountIdDest > 0)) {
            require(_accountProofs.length == 2, ErrMsg.REQ_TWO_ACCT);
        } else if (dsi.accountId > 0) {
            require(_accountProofs.length == 1, ErrMsg.REQ_ONE_ACCT);
        }

        // ------ #3: verify transition stateRoot == hash(accountStateRoot, strategyStateRoot, stakingPoolStateRoot, globalInfoHash)
        // All stateRoots for the subtrees must always be given irrespective of what is being disputed.
        require(
            _checkMultiTreeStateRoot(
                dsi.preStateRoot,
                _accountProofs[0].stateRoot,
                _strategyProof.stateRoot,
                _stakingPoolProof.stateRoot,
                transitionEvaluator.getGlobalInfoHash(_globalInfo)
            ),
            ErrMsg.REQ_BAD_NTREE
        );
        for (uint256 i = 1; i < _accountProofs.length; i++) {
            require(_accountProofs[i].stateRoot == _accountProofs[0].stateRoot, ErrMsg.REQ_BAD_SROOT);
        }

        // ------ #4: verify account, strategy and staking pool inclusion
        if (dsi.accountId > 0) {
            for (uint256 i = 0; i < _accountProofs.length; i++) {
                _verifyProofInclusion(
                    _accountProofs[i].stateRoot,
                    transitionEvaluator.getAccountInfoHash(_accountProofs[i].value),
                    _accountProofs[i].index,
                    _accountProofs[i].siblings
                );
            }
        }
        if (dsi.strategyId > 0) {
            _verifyProofInclusion(
                _strategyProof.stateRoot,
                transitionEvaluator.getStrategyInfoHash(_strategyProof.value),
                _strategyProof.index,
                _strategyProof.siblings
            );
        }
        if (dsi.stakingPoolId > 0) {
            _verifyProofInclusion(
                _stakingPoolProof.stateRoot,
                transitionEvaluator.getStakingPoolInfoHash(_stakingPoolProof.value),
                _stakingPoolProof.index,
                _stakingPoolProof.siblings
            );
        }

        // ------ #5: verify deposit account id mapping
        uint8 transitionType = tn.extractTransitionType(_invalidTransitionProof.transition);
        if (transitionType == tn.TN_TYPE_DEPOSIT) {
            dt.DepositTransition memory transition =
                tn.decodePackedDepositTransition(_invalidTransitionProof.transition);
            if (
                _accountProofs[0].value.account == transition.account &&
                _accountProofs[0].value.accountId != dsi.accountId
            ) {
                // same account address with different id
                return "bad account id";
            }
        }

        // ------ #6: verify transition account, strategy, staking pool indexes
        if (dsi.accountId > 0) {
            require(_accountProofs[0].index == dsi.accountId, ErrMsg.REQ_BAD_INDEX);
            if (dsi.accountIdDest > 0) {
                require(_accountProofs[1].index == dsi.accountIdDest, ErrMsg.REQ_BAD_INDEX);
            }
        }
        if (dsi.strategyId > 0) {
            require(_strategyProof.index == dsi.strategyId, ErrMsg.REQ_BAD_INDEX);
        }
        if (dsi.stakingPoolId > 0) {
            require(_stakingPoolProof.index == dsi.stakingPoolId, ErrMsg.REQ_BAD_INDEX);
        }

        // ------ #7: evaluate transition and verify new state root
        // split function to address "stack too deep" compiler error
        return
            _evaluateInvalidTransition(
                _invalidTransitionProof,
                _accountProofs,
                _strategyProof,
                _stakingPoolProof,
                _globalInfo,
                dsi.postStateRoot,
                _registry
            );
    }

    /*********************
     * Private Functions *
     *********************/

    /**
     * @notice Evaluate a disputed transition
     * @dev This was split from the disputeTransition function to address "stack too deep" compiler error
     *
     * @param _invalidTransitionProof The inclusion proof of the fraudulent transition.
     * @param _accountProofs The inclusion proofs of one or two accounts involved.
     * @param _strategyProof The inclusion proof of the strategy involved.
     * @param _stakingPoolProof The inclusion proof of the staking pool involved.
     * @param _globalInfo The global info.
     * @param _postStateRoot State root of the disputed transition.
     * @param _registry The address of the Registry contract.
     */
    function _evaluateInvalidTransition(
        dt.TransitionProof calldata _invalidTransitionProof,
        dt.AccountProof[] calldata _accountProofs,
        dt.StrategyProof calldata _strategyProof,
        dt.StakingPoolProof calldata _stakingPoolProof,
        dt.GlobalInfo calldata _globalInfo,
        bytes32 _postStateRoot,
        Registry _registry
    ) private returns (string memory) {
        // Apply the transaction and verify the state root after that.
        bool ok;
        bytes memory returnData;

        dt.AccountInfo[] memory accountInfos = new dt.AccountInfo[](_accountProofs.length);
        for (uint256 i = 0; i < _accountProofs.length; i++) {
            accountInfos[i] = _accountProofs[i].value;
        }

        dt.EvaluateInfos memory infos =
            dt.EvaluateInfos({
                accountInfos: accountInfos,
                strategyInfo: _strategyProof.value,
                stakingPoolInfo: _stakingPoolProof.value,
                globalInfo: _globalInfo
            });
        (
            // Make the external call
            ok,
            returnData
        ) = address(transitionEvaluator).call(
            abi.encodeWithSelector(
                transitionEvaluator.evaluateTransition.selector,
                _invalidTransitionProof.transition,
                infos,
                _registry
            )
        );
        // Check if it was successful. If not, we've got to revert.
        if (!ok) {
            return "failed to evaluate";
        }
        // It was successful so let's decode the outputs to get the new leaf nodes we'll have to insert
        bytes32[5] memory outputs = abi.decode((returnData), (bytes32[5]));

        // Check if the combined new stateRoots of the Merkle trees is incorrect.
        ok = _updateAndVerify(_postStateRoot, outputs, _accountProofs, _strategyProof, _stakingPoolProof);
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
        uint32 stakingPoolId;
        disputeStateInfo memory dsi;

        // First decode the prestate root
        (success, returnData) = address(transitionEvaluator).call(
            abi.encodeWithSelector(transitionEvaluator.getTransitionStateRootAndAccessIds.selector, _preStateTransition)
        );

        // Make sure the call was successful
        require(success, ErrMsg.REQ_BAD_PREV_TN);
        (preStateRoot, , , , ) = abi.decode((returnData), (bytes32, uint32, uint32, uint32, uint32));

        // Now that we have the prestateRoot, let's decode the postState
        (success, returnData) = address(transitionEvaluator).call(
            abi.encodeWithSelector(TransitionEvaluator.getTransitionStateRootAndAccessIds.selector, _invalidTransition)
        );

        // If the call was successful let's decode!
        if (success) {
            (postStateRoot, accountId, accountIdDest, strategyId, stakingPoolId) = abi.decode(
                (returnData),
                (bytes32, uint32, uint32, uint32, uint32)
            );
            dsi.preStateRoot = preStateRoot;
            dsi.postStateRoot = postStateRoot;
            dsi.accountId = accountId;
            dsi.accountIdDest = accountIdDest;
            dsi.strategyId = strategyId;
            dsi.stakingPoolId = stakingPoolId;
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
        require(_checkTransitionInclusion(_initTransitionProof, _firstBlock), ErrMsg.REQ_TN_NOT_IN);
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
            require(_tp0.index + 1 == _tp1.index, ErrMsg.REQ_TN_NOT_SEQ);
            require(_tp1.index < _invalidTransitionBlock.blockSize, ErrMsg.REQ_TN_NOT_SEQ);
        } else {
            // If not in the same block, check that:
            // 0) the blocks are one after another
            require(_tp0.blockId + 1 == _tp1.blockId, ErrMsg.REQ_TN_NOT_SEQ);

            // 1) the index of tp0 is the last in its block
            require(_tp0.index == _prevTransitionBlock.blockSize - 1, ErrMsg.REQ_TN_NOT_SEQ);

            // 2) the index of tp1 is the first in its block
            require(_tp1.index == 0, ErrMsg.REQ_TN_NOT_SEQ);
        }

        // Verify inclusion
        require(_checkTransitionInclusion(_tp0, _prevTransitionBlock), ErrMsg.REQ_TN_NOT_IN);
        require(_checkTransitionInclusion(_tp1, _invalidTransitionBlock), ErrMsg.REQ_TN_NOT_IN);

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
     * @dev hash(accountStateRoot, strategyStateRoot, stakingPoolStateRoot, globalInfoHash)
     */
    function _checkMultiTreeStateRoot(
        bytes32 _stateRoot,
        bytes32 _accountStateRoot,
        bytes32 _strategyStateRoot,
        bytes32 _stakingPoolStateRoot,
        bytes32 _globalInfoHash
    ) private pure returns (bool) {
        bytes32 newStateRoot =
            keccak256(abi.encodePacked(_accountStateRoot, _strategyStateRoot, _stakingPoolStateRoot, _globalInfoHash));
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
        require(ok, ErrMsg.REQ_BAD_MERKLE);
    }

    /**
     * @notice Update the account, strategy, staking pool, and global info Merkle trees with their new leaf nodes and check validity.
     * @dev The _leafHashes array holds: [account (src), account (dest), strategy, stakingPool, globalInfo].
     */
    function _updateAndVerify(
        bytes32 _stateRoot,
        bytes32[5] memory _leafHashes,
        dt.AccountProof[] memory _accountProofs,
        dt.StrategyProof memory _strategyProof,
        dt.StakingPoolProof memory _stakingPoolProof
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
            strategyStateRoot = MerkleTree.computeRoot(_leafHashes[2], _strategyProof.index, _strategyProof.siblings);
        }

        // If there is a staking pool update, compute its new Merkle tree root.
        bytes32 stakingPoolStateRoot = _stakingPoolProof.stateRoot;
        if (_leafHashes[3] != bytes32(0)) {
            stakingPoolStateRoot = MerkleTree.computeRoot(
                _leafHashes[3],
                _stakingPoolProof.index,
                _stakingPoolProof.siblings
            );
        }

        return
            _checkMultiTreeStateRoot(
                _stateRoot,
                accountStateRoot,
                strategyStateRoot,
                stakingPoolStateRoot,
                _leafHashes[4] /* globalInfoHash */
            );
    }
}
