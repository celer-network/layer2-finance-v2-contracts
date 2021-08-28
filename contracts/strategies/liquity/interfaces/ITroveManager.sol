// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.6;

// Common interface for the Trove Manager.
interface ITroveManager {
    enum Status {
        nonExistent,
        active,
        closedByOwner,
        closedByLiquidation,
        closedByRedemption
    }

    function getTroveOwnersCount() external view returns (uint256);

    function getTroveFromTroveOwnersArray(uint256 _index) external view returns (address);

    function getNominalICR(address _borrower) external view returns (uint256);

    /**
     * Computes the user’s individual collateralization ratio (ICR) based on their total collateral and total LUSD debt.
     * Returns 2^256 -1 if they have 0 debt.
     */
    function getCurrentICR(address _borrower, uint256 _price) external view returns (uint256);

    function liquidate(address _borrower) external;

    function liquidateTroves(uint256 _n) external;

    function batchLiquidateTroves(address[] calldata _troveArray) external;

    function redeemCollateral(
        uint256 _LUSDAmount,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintNICR,
        uint256 _maxIterations,
        uint256 _maxFee
    ) external;

    function updateStakeAndTotalStakes(address _borrower) external returns (uint256);

    function updateTroveRewardSnapshots(address _borrower) external;

    function addTroveOwnerToArray(address _borrower) external returns (uint256 index);

    function applyPendingRewards(address _borrower) external;

    function getPendingETHReward(address _borrower) external view returns (uint256);

    function getPendingLUSDDebtReward(address _borrower) external view returns (uint256);

    function hasPendingRewards(address _borrower) external view returns (bool);

    /*
     * returns a Trove’s entire debt and collateral, which respectively include any pending debt rewards and ETH rewards from prior redistributions.
     */
    function getEntireDebtAndColl(address _borrower)
        external
        view
        returns (
            uint256 debt,
            uint256 coll,
            uint256 pendingLUSDDebtReward,
            uint256 pendingETHReward
        );

    function closeTrove(address _borrower) external;

    function removeStake(address _borrower) external;

    function getRedemptionRate() external view returns (uint256);

    function getBorrowingRate() external view returns (uint256);

    function getBorrowingFee(uint256 LUSDDebt) external view returns (uint256);

    function getBorrowingFeeWithDecay(uint256 LUSDDebt) external view returns (uint256);

    function decayBaseRateFromBorrowing() external;

    function getTroveStatus(address _borrower) external view returns (uint256);

    function getTroveStake(address _borrower) external view returns (uint256);

    function getTroveDebt(address _borrower) external view returns (uint256);

    function getTroveColl(address _borrower) external view returns (uint256);

    function setTroveStatus(address _borrower, uint256 num) external;

    function increaseTroveColl(address _borrower, uint256 _collIncrease) external returns (uint256);

    function decreaseTroveColl(address _borrower, uint256 _collDecrease) external returns (uint256);

    function increaseTroveDebt(address _borrower, uint256 _debtIncrease) external returns (uint256);

    function decreaseTroveDebt(address _borrower, uint256 _collDecrease) external returns (uint256);

    function getTCR(uint256 _price) external view returns (uint256);

    function checkRecoveryMode(uint256 _price) external view returns (bool);

    // Minimum amount of net LUSD debt a trove must have
    function MIN_NET_DEBT() external view returns (uint256);

    function LUSD_GAS_COMPENSATION() external view returns (uint256);
}
