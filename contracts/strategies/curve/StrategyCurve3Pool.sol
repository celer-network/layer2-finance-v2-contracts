// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../interfaces/IWETH.sol";
import "../interfaces/uniswap/IUniswapV2.sol";
import "../interfaces/curve/ICurveFi.sol";
import "../interfaces/curve/IGauge.sol";
import "../interfaces/curve/IMintr.sol";
import "../AbstractStrategy.sol";

contract StrategyCurve3Pool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public slippage = 500;
    uint256 public constant SLIPPAGE_DENOMINATOR = 10000;

    address public pool;
    address public gauge;
    address public mintr;
    address public uniswap;
    address public crv;
    address public weth;
    address public lpToken;
    uint8 public supplyTokenIndexInPool;
    uint256 public decimalDiff;

    constructor(
        address _controller,
        address _lpToken,
        address _supplyToken, // has to be weth in this strategy
        uint8 _supplyTokenIndexInPool,
        address _pool,
        address _gauge,
        address _mintr,
        address _crv,
        address _weth,
        address _uniswap,
        uint8 _supplyTokenDecimal
    ) AbstractStrategy(_controller, _supplyToken) {
        pool = _pool;
        gauge = _gauge;
        mintr = _mintr;
        crv = _crv;
        weth = _weth;
        uniswap = _uniswap;
        lpToken = _lpToken;
        supplyTokenIndexInPool = _supplyTokenIndexInPool;
        decimalDiff = PRICE_DECIMALS / 10**_supplyTokenDecimal; // curve lp token as they have 18 decimals but tokens like USDC USDT actually have 6 decimals
    }

    function getAssetAmount() internal view override returns (uint256) {
        uint256 lpTokenBalance = IGauge(gauge).balanceOf(address(this));
        return ((lpTokenBalance * ICurveFi(pool).get_virtual_price()) / decimalDiff) / PRICE_DECIMALS;
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        // pull fund from controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        uint256 obtainedLpTokens = _addLiquidity(_buyAmount);

        // deposit bought LP tokens to curve gauge to farm CRV
        IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpTokens);
        IGauge(gauge).deposit(obtainedLpTokens);

        uint256 obtainedUnderlyingAsset = ((obtainedLpTokens * ICurveFi(pool).get_virtual_price()) / decimalDiff) /
            PRICE_DECIMALS;
        return obtainedUnderlyingAsset;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        uint256 sellLpTokens = (_sellAmount * PRICE_DECIMALS * decimalDiff) / ICurveFi(pool).get_virtual_price();
        // unstake from needed lpTokens for sell from gauge
        IGauge(gauge).withdraw(sellLpTokens);

        // remove liquidity from pool
        uint256 minAmountFromSell = (_sellAmount * (SLIPPAGE_DENOMINATOR - slippage)) / SLIPPAGE_DENOMINATOR;
        uint256 balanceBeforeSell = IERC20(supplyToken).balanceOf(address(this));
        ICurveFi(pool).remove_liquidity_one_coin(sellLpTokens, int8(supplyTokenIndexInPool), minAmountFromSell);
        uint256 obtainedSupplyToken = IERC20(supplyToken).balanceOf(address(this)) - balanceBeforeSell;
        IERC20(supplyToken).safeTransfer(msg.sender, obtainedSupplyToken);

        return obtainedSupplyToken;
    }

    function harvest() external override onlyOwnerOrController {
        IMintr(mintr).mint(gauge);
        uint256 crvBalance = IERC20(crv).balanceOf(address(this));

        if (crvBalance > 0) {
            uint256 originalBalance = IERC20(supplyToken).balanceOf(address(this));

            // Sell CRV for more supply token
            IERC20(crv).safeIncreaseAllowance(uniswap, crvBalance);
            address[] memory path = new address[](3);
            path[0] = crv;
            path[1] = weth;
            path[2] = supplyToken;

            IUniswapV2(uniswap).swapExactTokensForTokens(
                crvBalance,
                uint256(0),
                path,
                address(this),
                block.timestamp + 1800
            );

            // Re-invest supply token to obtain more lpToken
            uint256 obtainedAssetAmount = IERC20(supplyToken).balanceOf(address(this)) - originalBalance;
            uint256 obtainedLpToken = _addLiquidity(obtainedAssetAmount);

            // Stake lpToken in Gauge to farm more CRV
            IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpToken);
            IGauge(gauge).deposit(obtainedLpToken);
        }
    }

    function _addLiquidity(uint256 _buyAmount) private returns (uint256) {
        uint256 originalLpTokenBalance = IERC20(lpToken).balanceOf(address(this));
        uint256 minMintAmount = (((_buyAmount * PRICE_DECIMALS * decimalDiff) / ICurveFi(pool).get_virtual_price()) *
            (SLIPPAGE_DENOMINATOR - slippage)) / SLIPPAGE_DENOMINATOR;
        uint256[3] memory amounts;
        amounts[supplyTokenIndexInPool] = _buyAmount;
        IERC20(supplyToken).safeIncreaseAllowance(pool, _buyAmount);
        ICurveFi(pool).add_liquidity(amounts, minMintAmount);

        uint256 obtainedLpToken = IERC20(lpToken).balanceOf(address(this)) - originalLpTokenBalance;
        return obtainedLpToken;
    }

    function setSlippage(uint256 _slippage) external onlyOwner {
        slippage = _slippage;
    }
}
