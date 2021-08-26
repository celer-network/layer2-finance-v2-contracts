// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.6;

interface IPriceFeed {
    // --- Function ---
    function fetchPrice() external returns (uint256);
}
