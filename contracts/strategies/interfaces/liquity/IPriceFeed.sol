// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;

interface IPriceFeed {
    // --- Function ---
    function fetchPrice() external returns (uint);
}