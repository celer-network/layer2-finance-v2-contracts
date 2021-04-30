// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Interface for DeFi strategies
 *
 * @notice Strategy provides abstraction for a DeFi strategy.
 */
interface IStrategy is IERC20 {
    event Buy(uint256 amount, uint256 sharesFromBuy);

    event Sell(uint256 shares, uint256 amountFromSell);

    event ControllerChanged(address previousController, address newController);

    /**
     * @notice Returns the address of the asset token.
     */
    function getAssetAddress() external view returns (address);

    /**
     * @notice Compounding of extra yields
     */
    function harvest() external;

    /**
     * @notice Syncs and returns the price of each share
     */
    function syncPrice() external returns (uint256);

    /**
     * @notice aggregate orders to strategy per instructions from L2.
     *
     * @param buyAmount The aggregated asset amount to buy.
     * @param minSharesFromBuy Minimal shares from buy.
     * @param sellShares The aggregated shares to sell.
     * @param minAmountFromSell Minimal asset amount from sell.
     * @return (sharesFromBuy, amountFromSell)
     */
    function aggregateOrder(
        uint256 buyAmount,
        uint256 minSharesFromBuy,
        uint256 sellShares,
        uint256 minAmountFromSell
    ) external returns (uint256, uint256);

    /**
     * @notice Redeem shares, used by force sell.
     *
     * @param shares Amount of shares to redeem
     */
    function redeemShares(uint256 shares) external;
}
