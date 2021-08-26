// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.6;

// Common interface for the Trove Manager.
interface IBorrowerOperations {
    function openTrove(
        uint256 _maxFee,
        uint256 _LUSDAmount,
        address _upperHint,
        address _lowerHint
    ) external payable;

    function addColl(address _upperHint, address _lowerHint) external payable;

    function withdrawColl(
        uint256 _amount,
        address _upperHint,
        address _lowerHint
    ) external;

    /**
     * Issues _amount of LUSD from the caller’s Trove to the caller.
     */
    function withdrawLUSD(
        uint256 _maxFee,
        uint256 _amount,
        address _upperHint,
        address _lowerHint
    ) external;

    /**
     * Repays _amount of LUSD to the caller’s Trove, subject to leaving 50 debt in the Trove (which corresponds to the 50 LUSD gas compensation).
     */
    function repayLUSD(
        uint256 _amount,
        address _upperHint,
        address _lowerHint
    ) external;

    function closeTrove() external;

    function adjustTrove(
        uint256 _maxFee,
        uint256 _collWithdrawal,
        uint256 _debtChange,
        bool isDebtIncrease,
        address _upperHint,
        address _lowerHint
    ) external payable;

    function claimCollateral() external;

    function getCompositeDebt(uint256 _debt) external pure returns (uint256);
}
