// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;

interface IGauge {
    function deposit(uint256) external;

    function balanceOf(address) external view returns (uint256);

    function withdraw(uint256) external;

    function claim_rewards(address) external;

    function rewarded_token() external returns (address);

    function reward_tokens(uint256) external returns (address);

    function claimable_tokens(address) external returns (uint256);
}
