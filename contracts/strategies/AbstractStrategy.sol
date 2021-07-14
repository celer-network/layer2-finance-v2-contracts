// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IStrategy.sol";

import "hardhat/console.sol";

abstract contract AbstractStrategy is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 constant MAX_INT = 2**256 - 1;
    uint256 constant PRICE_DECIMALS = 1e18;

    address public controller;
    address public supplyToken;
    address public lpToken;

    uint256 public shares;

    constructor(
        address _controller,
        address _supplyToken,
        address _lpToken
    ) {
        controller = _controller;
        supplyToken = _supplyToken;
        lpToken = _lpToken;
    }

    modifier onlyController() {
        require(msg.sender == controller, "caller is not controller");
        _;
    }

    modifier onlyOwnerOrController() {
        require(msg.sender == owner() || msg.sender == controller, "caller is not owner or controller");
        _;
    }

    /**
     * @return The underlying asset amount of the supply token with 18 decimals
     */
    function getAssetAmount() public view virtual returns (uint256);

    /**
     * @notice Buys lp token from defi contract
     * @param _buyAmount the amount of underlying asset to be deposited
     * @return The obtained amount of underlying asset after execution
     */
    function buy(uint256 _buyAmount) internal virtual returns (uint256);

    /**
     * @notice Sells lp token to defi contract for supply token
     * @param _sellAmount the amount of supply token intended to be redeemed from defi
     * @return The amount of supply tokens redeemed
     */
    function sell(uint256 _sellAmount) internal virtual returns (uint256);

    function getAssetAddress() external view override returns (address) {
        return supplyToken;
    }

    function aggregateOrders(
        uint256 _buyAmount,
        uint256 _sellShares,
        uint256 _minSharesFromBuy,
        uint256 _minAmountFromSell
    ) external override onlyController returns (uint256, uint256) {
        require(msg.sender == controller, "Not controller");

        uint256 amountFromSell;
        uint256 sharesFromBuy;
        uint256 sharePrice = this.syncPrice();

        if (shares == 0) {
            sharesFromBuy = _buyAmount;
        } else {
            amountFromSell = (_sellShares * sharePrice) / PRICE_DECIMALS;
            sharesFromBuy = (_buyAmount * PRICE_DECIMALS) / sharePrice;
        }

        if (amountFromSell < _buyAmount) {
            uint256 buyAmount = _buyAmount - amountFromSell;
            uint256 actualSharesFromBuy = _doBuy(buyAmount);
            uint256 totalSharesFromBuy = actualSharesFromBuy + _sellShares;
            require(totalSharesFromBuy >= _minSharesFromBuy, "failed min shares from buy");
            emit Buy(_buyAmount, totalSharesFromBuy);
            emit Sell(_sellShares, amountFromSell);
            return (totalSharesFromBuy, amountFromSell);
        } else if (amountFromSell > _buyAmount) {
            uint256 sellShares = _sellShares - sharesFromBuy;
            uint256 actualAmountFromSell = _doSell(sellShares);
            uint256 totalAmountFromSell = actualAmountFromSell + _buyAmount;
            require(totalAmountFromSell >= _minAmountFromSell, "failed min amount from sell");
            emit Buy(_buyAmount, sharesFromBuy);
            emit Sell(_sellShares, totalAmountFromSell);
            return (sharesFromBuy, actualAmountFromSell);
        }

        emit Buy(_buyAmount, sharesFromBuy);
        emit Sell(_sellShares, amountFromSell);
        return (sharesFromBuy, amountFromSell);
    }

    function _doBuy(uint256 _buyAmount) private returns (uint256) {
        uint256 assetAmountBeforeBuy = getAssetAmount();
        uint256 obtainedUnderlyingAsset = buy(_buyAmount);
        uint256 actualSharesFromBuy;
        if (shares == 0) {
            actualSharesFromBuy = obtainedUnderlyingAsset;
        } else {
            actualSharesFromBuy = (obtainedUnderlyingAsset * shares) / assetAmountBeforeBuy;
        }
        shares += actualSharesFromBuy;
        return actualSharesFromBuy;
    }

    function _doSell(uint256 _sellShares) private returns (uint256) {
        uint256 assetAmountBeforeSell = getAssetAmount();
        uint256 sellAmount = (_sellShares * this.syncPrice()) / PRICE_DECIMALS;
        uint256 redeemedUnderlyingAsset = sell(sellAmount);
        IERC20(supplyToken).safeTransfer(msg.sender, redeemedUnderlyingAsset);
        uint256 actualSharesFromSell = (redeemedUnderlyingAsset * shares) / assetAmountBeforeSell;
        shares -= actualSharesFromSell;
        return redeemedUnderlyingAsset;
    }

    function syncPrice() external view override returns (uint256) {
        uint256 assetAmount = getAssetAmount();
        if (shares == 0) {
            if (assetAmount == 0) {
                return PRICE_DECIMALS;
            }
            return MAX_INT;
        }
        return (assetAmount * PRICE_DECIMALS) / shares;
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }
}
