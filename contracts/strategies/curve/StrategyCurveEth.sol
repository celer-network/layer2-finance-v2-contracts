// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/IWETH.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/uniswap/IUniswapV2.sol";
import "../interfaces/curve/ICurveFi.sol";
import "../interfaces/curve/IGauge.sol";
import "../interfaces/curve/IMintr.sol";

contract StrategyCurveEth is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    address public controller;

    uint256 constant MAX_INT = 2**256 - 1;
    uint256 constant PRICE_DECIMALS = PRICE_DECIMALS;
    uint256 public constant SLIPPAGE_NUMERATOR = 500;
    uint256 public constant SLIPPAGE_DENOMINATOR = 10000;

    // contract addresses
    address public pool; // swap pool
    address public gauge; // Curve gauge
    address public mintr; // Curve minter
    address public uniswap; // UniswapV2

    // supply token params
    uint8 public supplyTokenIndexInPool = 0; // ETH - 0, Other - 1

    // token addresses
    address public lpToken; // LP token
    address public crv; // CRV token
    address public weth; // WETH token

    uint256 public shares;

    constructor(
        address _controller,
        uint8 _supplyTokenIndexInPool,
        address _pool,
        address _lpToken,
        address _gauge,
        address _mintr,
        address _crv,
        address _weth,
        address _uniswap
    ) {
        controller = _controller;
        supplyTokenIndexInPool = _supplyTokenIndexInPool;
        pool = _pool;
        lpToken = _lpToken;
        gauge = _gauge;
        mintr = _mintr;
        crv = _crv;
        weth = _weth;
        uniswap = _uniswap;
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
        return weth;
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
        uint256 lpTokenPrice = ICurveFi(pool).get_virtual_price();
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
            uint256 actualSharesFromBuy = _buy(buyAmount);
            shares += actualSharesFromBuy;
            uint256 totalSharesFromBuy = actualSharesFromBuy + _sellShares;
            require(totalSharesFromBuy >= _minSharesFromBuy, "failed min shares from buy");
            emit Buy(_buyAmount, totalSharesFromBuy);
            return (actualSharesFromBuy, 0);
        } else if (amountFromSell > _buyAmount) {
            uint256 sellLpTokens = ((((_sellShares - sharesFromBuy) * sharePrice) / PRICE_DECIMALS) * lpTokenPrice) /
                PRICE_DECIMALS;
            uint256 actualAmountFromSell = _sell(sellLpTokens);
            shares -= actualAmountFromSell / this.syncPrice();
            uint256 totalAmountFromSell = actualAmountFromSell + _buyAmount;
            require(totalAmountFromSell >= _minAmountFromSell, "failed min amount from sell");
            emit Sell(_sellShares, totalAmountFromSell);
            return (0, actualAmountFromSell);
        }

        return (0, 0);
    }

    function _buy(uint256 _buyAmount) private returns (uint256) {
        uint256 minLpTokenFromBuy = ((_buyAmount * (ICurveFi(pool).get_virtual_price() / PRICE_DECIMALS)) *
            SLIPPAGE_NUMERATOR) / SLIPPAGE_DENOMINATOR;

        // pull fund from controller
        IERC20(weth).safeTransferFrom(msg.sender, address(this), _buyAmount);
        IWETH(weth).withdraw(_buyAmount);

        // add liquidity in pool
        uint256[2] memory amounts;
        amounts[supplyTokenIndexInPool] = _buyAmount;
        ICurveFi(pool).add_liquidity{value: _buyAmount}(amounts, minLpTokenFromBuy);
        uint256 obtainedLpTokens = IERC20(lpToken).balanceOf(address(this));

        // deposit bought LP tokens to curve gauge to farm CRV
        IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpTokens);
        IGauge(gauge).deposit(obtainedLpTokens);

        uint256 actualSharesFromBuy = (obtainedLpTokens * PRICE_DECIMALS) /
            ICurveFi(pool).get_virtual_price() /
            this.syncPrice();

        return actualSharesFromBuy;
    }

    function _sell(uint256 _sellLpTokens) private returns (uint256) {
        uint256 minAmountFromSell = (((_sellLpTokens * PRICE_DECIMALS) / ICurveFi(pool).get_virtual_price()) *
            SLIPPAGE_NUMERATOR) / SLIPPAGE_DENOMINATOR;

        // pull shares from controller
        IERC20(weth).safeTransferFrom(msg.sender, address(this), _sellLpTokens);

        // remove liquidity from pool
        ICurveFi(pool).remove_liquidity_one_coin(_sellLpTokens, int8(supplyTokenIndexInPool), minAmountFromSell);

        uint256 actualAmountFromSell = address(this).balance;

        // wrap ETH and send back to controller
        IWETH(weth).deposit{value: actualAmountFromSell}();
        IERC20(weth).safeTransfer(msg.sender, actualAmountFromSell);

        return actualAmountFromSell;
    }

    function syncPrice() external view override returns (uint256) {
        uint256 assetAmount = IERC20(lpToken).balanceOf(address(msg.sender)) / ICurveFi(pool).get_virtual_price();
        if (shares == 0) {
            if (assetAmount == 0) {
                return PRICE_DECIMALS;
            }
            return MAX_INT;
        }
        return (assetAmount * PRICE_DECIMALS) / shares;
    }

    function harvest() external override onlyOwnerOrController {
        IMintr(mintr).mint(gauge);
        uint256 crvBalance = IERC20(crv).balanceOf(address(this));

        if (crvBalance > 0) {
            // Sell CRV for more supply token
            IERC20(crv).safeIncreaseAllowance(uniswap, crvBalance);

            address[] memory path = new address[](2);
            path[0] = crv;
            path[1] = weth;

            IUniswapV2(uniswap).swapExactTokensForETH(
                crvBalance,
                uint256(0),
                path,
                address(this),
                block.timestamp + 1800
            );

            // Re-invest supply token to obtain more lpToken
            uint256 obtainedAssetAmount = address(this).balance;
            uint256 minMintAmount = (((obtainedAssetAmount * PRICE_DECIMALS) / ICurveFi(pool).get_virtual_price()) *
                SLIPPAGE_NUMERATOR) / SLIPPAGE_DENOMINATOR;
            uint256[2] memory amounts;
            amounts[supplyTokenIndexInPool] = obtainedAssetAmount;
            ICurveFi(pool).add_liquidity{value: obtainedAssetAmount}(amounts, minMintAmount);

            // Stake lpToken in Gauge to farm more CRV
            uint256 obtainedLpToken = IERC20(lpToken).balanceOf(address(this));
            IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpToken);
            IGauge(gauge).deposit(obtainedLpToken);
        }
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }
}
