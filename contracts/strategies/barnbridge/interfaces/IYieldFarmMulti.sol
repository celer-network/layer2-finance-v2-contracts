// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

interface IYieldFarmMulti {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function claim_allTokens() external returns (uint256[] memory);
}
