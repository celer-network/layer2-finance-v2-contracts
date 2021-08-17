// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

// Iron bank aka. Yearn Token. only need exchangeRateStored to calculate underlying asset
// note it's actually just using compound contract so we could use full CTokenInterfaces.sol
interface IYearnToken {
    // exchange rate scaled by 1e18
    function exchangeRateStored() external view returns (uint);
    // current to ensure token computed for sell is accurate
    function exchangeRateCurrent() external returns (uint);
}