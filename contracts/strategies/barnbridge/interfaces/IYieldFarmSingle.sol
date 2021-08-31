// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

interface IYieldFarmSingle {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function claim() external returns (uint256);
}
