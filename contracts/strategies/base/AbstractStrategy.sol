// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/IStrategy.sol";

abstract contract AbstractStrategy is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 constant MAX_INT = 2**256 - 1;
    uint256 constant PRICE_DECIMALS = 1e18;

    address public controller;
    address public immutable supplyToken;

    uint256 public shares;

    constructor(address _controller, address _supplyToken) {
        controller = _controller;
        supplyToken = _supplyToken;
    }

    modifier onlyController() {
        require(msg.sender == controller, "caller is not controller");
        _;
    }

    modifier onlyOwnerOrController() {
        require(msg.sender == owner() || msg.sender == controller, "caller is not owner or controller");
        _;
    }

    function getAssetAddress() external view override returns (address) {
        return supplyToken;
    }

    /**
     * @return The underlying asset amount of the supply token with 18 decimals
     */
    function getAssetAmount() public view virtual override returns (uint256);

    function getPrice() public view override returns (uint256) {
        uint256 assetAmount = getAssetAmount();
        if (shares == 0) {
            if (assetAmount == 0) {
                return PRICE_DECIMALS;
            }
            return MAX_INT;
        }
        return (assetAmount * PRICE_DECIMALS) / shares;
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
        uint256 sharePrice = getPrice();

        if (shares == 0) {
            sharesFromBuy = _buyAmount;
        } else {
            amountFromSell = (_sellShares * sharePrice) / PRICE_DECIMALS;
            sharesFromBuy = (_buyAmount * PRICE_DECIMALS) / sharePrice;
        }

        uint256 totalSharesFromBuy = sharesFromBuy;
        uint256 totalAmountFromSell = amountFromSell;

        if (amountFromSell < _buyAmount) {
            uint256 buyAmount = _buyAmount - amountFromSell;
            uint256 actualSharesFromBuy = _doBuy(buyAmount);
            totalSharesFromBuy = actualSharesFromBuy + _sellShares;
            require(totalSharesFromBuy >= _minSharesFromBuy, "failed min shares from buy");
        } else if (amountFromSell > _buyAmount) {
            uint256 sellShares = _sellShares - sharesFromBuy;
            uint256 actualAmountFromSell = _doSell(sellShares);
            totalAmountFromSell = actualAmountFromSell + _buyAmount;
            require(totalAmountFromSell >= _minAmountFromSell, "failed min amount from sell");
        }

        if (totalSharesFromBuy > 0) {
            emit Buy(_buyAmount, totalSharesFromBuy);
        }
        if (totalAmountFromSell > 0) {
            emit Sell(_sellShares, totalAmountFromSell);
        }
        return (totalSharesFromBuy, totalAmountFromSell);
    }

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
        uint256 sellAmount = (_sellShares * getPrice()) / PRICE_DECIMALS;
        uint256 redeemedUnderlyingAsset = sell(sellAmount);
        uint256 actualSharesFromSell = (redeemedUnderlyingAsset * shares) / assetAmountBeforeSell;
        shares -= actualSharesFromSell;
        return redeemedUnderlyingAsset;
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }

    function harvest() external virtual override {}

    function adjust() external virtual override {}

    /**
     * Override this to add all tokens/tokenized positions this contract
     * manages on a *persistent* basis (e.g. not just for swapping back to
     * supplyToken ephemerally).
     *
     * NOTE: Do *not* include `supplyToken`, already included in `sweep` below.
     *
     * Example:
     * ```
     *    function protectedTokens() internal override view returns (address[] memory) {
     *      address[] memory protected = new address[](3);
     *      protected[0] = tokenA;
     *      protected[1] = tokenB;
     *      protected[2] = tokenC;
     *      return protected;
     *    }
     * ```
     */
    function protectedTokens() internal view virtual returns (address[] memory) {}

    /**
     * @notice
     *  Removes tokens from this strategy that are not the type of tokens
     *  managed by this strategy. This may be used in case of accidentally
     *  sending the wrong kind of token to this strategy.
     *
     *  This will fail if an attempt is made to sweep `supplyToken`, or any tokens
     *  that are protected by this strategy.
     *
     *  This may only be called by the owner.
     * @dev
     *  Implement `protectedTokens()` to specify any additional tokens that
     *  should be protected from sweeping in addition to `supplyToken`.
     * @param _token The token to transfer out of this strategy.
     */
    function sweep(address _token) external onlyOwner {
        require(_token != address(supplyToken), "Cannot sweep supply token");

        address[] memory _protectedTokens = protectedTokens();
        for (uint256 i = 0; i < _protectedTokens.length; i++) {
            require(_token != _protectedTokens[i], "Cannot sweep protected token");
        }

        IERC20(_token).safeTransfer(msg.sender, IERC20(_token).balanceOf(address(this)));
    }
}
