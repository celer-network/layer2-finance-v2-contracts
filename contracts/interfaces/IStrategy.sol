// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Interface for DeFi strategies
 * @notice Strategy provides abstraction for a DeFi strategy.
 */
interface IStrategy {
    event Buy(uint256 amount, uint256 sharesFromBuy);

    event Sell(uint256 shares, uint256 amountFromSell);

    event ControllerChanged(address previousController, address newController);

    /**
     * @notice Returns the address of the asset token.
     */
    function getAssetAddress() external view returns (address);

    /**
     * @notice aggregate orders to strategy per instructions from L2.
     *
     * @param _buyAmount The aggregated asset amount to buy.
     * @param _sellShares The aggregated shares to sell.
     * @param _minSharesFromBuy Minimal shares from buy.
     * @param _minAmountFromSell Minimal asset amount from sell.
     * @return (sharesFromBuy, amountFromSell)
     */
    function aggregateOrders(
        uint256 _buyAmount,
        uint256 _sellShares,
        uint256 _minSharesFromBuy,
        uint256 _minAmountFromSell
    ) external returns (uint256, uint256);

    /**
     * @notice Syncs and returns the price of each share
     */
    function syncPrice() external returns (uint256);

    /**
     * @notice Compounding of extra yields
     */
    function harvest() external;
}
