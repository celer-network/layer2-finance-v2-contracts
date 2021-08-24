// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

interface IMasterChef {
    /// @notice Deposit LP tokens to MC for SUSHI allocation.
    /// @param pid The index of the pool.
    /// @param amount LP token amount to deposit.
    function deposit(uint256 pid, uint256 amount) external;

    /// @notice Withdraw LP tokens from MC.
    /// @param pid The index of the pool.
    /// @param amount LP token amount to withdraw.
    function withdraw(uint256 pid, uint256 amount) external;
}
