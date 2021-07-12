// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IWETH.sol";
import "./interfaces/IStrategy.sol";
import "./interfaces/uniswap/IUniswapV2.sol";
import "./interfaces/curve/ICurveFi.sol";
import "./interfaces/curve/IGauge.sol";
import "./interfaces/curve/IMintr.sol";

abstract contract AbstractStrategy is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 constant MAX_INT = 2**256 - 1;
    uint256 constant PRICE_DECIMALS = 1e8;
    uint256 public constant SLIPPAGE_NUMERATOR = 500;
    uint256 public constant SLIPPAGE_DENOMINATOR = 10000;

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
     * @notice Gets the price of the lpToken in terms of lpToken/supplyToken
     * @return The lp token price relative to supply token with 18 decimals
     */
    function getLpTokenPrice() public view virtual returns (uint256);

    /**
     * @notice Buys lp token from defi contract
     * @return The amount of lp tokens bought
     */
    function buy(uint256 _buyAmount, uint256 _minLpTokenFromBuy) internal virtual returns (uint256);

    /**
     * @notice Sells lp token to defi contract for
     * @return The amount of supply tokens redeemed
     */
    function sell(uint256 _sellLpTokens, uint256 _minAmountFromSell) internal virtual returns (uint256);

    function getAssetAddress() external view override returns (address) {
        return lpToken;
    }

    function aggregateOrders(
        uint256 _buyAmount,
        uint256 _sellShares,
        uint256 _minSharesFromBuy,
        uint256 _minAmountFromSell
    ) external override onlyController returns (uint256, uint256) {
        require(msg.sender == controller, "Not controller");
        require(shares >= _sellShares, "not enough shares to sell");

        uint256 amountFromSell;
        uint256 sharesFromBuy;
        uint256 lpTokenPrice = getLpTokenPrice();
        uint256 sharePrice = this.syncPrice();

        if (shares == 0) {
            shares = _buyAmount;
            sharesFromBuy = _buyAmount;
        } else {
            amountFromSell = (_sellShares * sharePrice) / PRICE_DECIMALS;
            sharesFromBuy = (_buyAmount * PRICE_DECIMALS) / sharePrice;
        }

        if (amountFromSell < _buyAmount) {
            uint256 buyAmount = _buyAmount - amountFromSell;
            uint256 minLpTokenFromBuy = ((_buyAmount * (getLpTokenPrice() / PRICE_DECIMALS)) * SLIPPAGE_NUMERATOR) /
                SLIPPAGE_DENOMINATOR;

            // execute buy
            uint256 obtainedLpTokens = buy(buyAmount, minLpTokenFromBuy);
            uint256 actualAmountFromBuy = (obtainedLpTokens * PRICE_DECIMALS) / getLpTokenPrice();
            uint256 actualSharesFromBuy = (actualAmountFromBuy * shares) /
                (actualAmountFromBuy + IERC20(lpToken).balanceOf(address(msg.sender)) / getLpTokenPrice());

            // add the bought amount equivalent of shares to shares state
            shares += actualSharesFromBuy;

            // make sure the shares acquired from buying matches controller's criteria
            uint256 totalSharesFromBuy = actualSharesFromBuy + _sellShares;
            require(totalSharesFromBuy >= _minSharesFromBuy, "failed min shares from buy");

            emit Buy(_buyAmount, totalSharesFromBuy);
            emit Sell(_sellShares, amountFromSell);
            return (totalSharesFromBuy, amountFromSell);
        } else if (amountFromSell > _buyAmount) {
            uint256 sellLpTokens = ((((_sellShares - sharesFromBuy) * sharePrice) / PRICE_DECIMALS) * lpTokenPrice) /
                PRICE_DECIMALS;
            uint256 minAmountFromSell = (((sellLpTokens * PRICE_DECIMALS) / getLpTokenPrice()) * SLIPPAGE_NUMERATOR) /
                SLIPPAGE_DENOMINATOR;

            // execute sell
            uint256 actualAmountFromSell = sell(sellLpTokens, minAmountFromSell);

            // transfer supplyToken obtained back to controller
            IERC20(supplyToken).safeTransfer(msg.sender, actualAmountFromSell);

            // subtract the sold shares from shares state
            shares -= actualAmountFromSell / this.syncPrice();

            // make sure the amount acquired from selling shares matches controller's criteria
            uint256 totalAmountFromSell = actualAmountFromSell + _buyAmount;
            require(totalAmountFromSell >= _minAmountFromSell, "failed min amount from sell");

            emit Buy(_buyAmount, sharesFromBuy);
            emit Sell(_sellShares, totalAmountFromSell);
            return (sharesFromBuy, actualAmountFromSell);
        }

        return (sharesFromBuy, amountFromSell);
    }

    function syncPrice() external view override returns (uint256) {
        uint256 assetAmount = IERC20(lpToken).balanceOf(address(msg.sender)) / getLpTokenPrice();
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
