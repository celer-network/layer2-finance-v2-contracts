// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.6;

interface IHintHelpers {
    /* getApproxHint() - return address of a Trove that is, on average, (length / numTrials) positions away in the
    sortedTroves list from the correct insert position of the Trove to be inserted.

    Note: The output address is worst-case O(n) positions away from the correct insert position, however, the function
    is probabilistic. Input can be tuned to guarantee results to a high degree of confidence, e.g:
    Submitting numTrials = k * sqrt(length), with k = 15 makes it very, very likely that the ouput address will
    be <= sqrt(length) positions away from the correct insert position.
    */
    function getApproxHint(
        uint256 _CR,
        uint256 _numTrials,
        uint256 _inputRandomSeed
    )
        external
        view
        returns (
            address hintAddress,
            uint256 diff,
            uint256 latestRandomSeed
        );
}
