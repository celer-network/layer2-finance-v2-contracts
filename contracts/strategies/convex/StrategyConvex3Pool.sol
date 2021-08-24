// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../base/AbstractStrategy.sol";
import "../curve/interfaces/ICurveFi.sol";
import "../uniswap-v2/interfaces/IUniswapV2Router02.sol";
import "./interfaces/IConvex.sol";
import "./interfaces/IConvexRewards.sol";

// add_liquidity to curve 3pool 0xbebc44782c7db0a1a60cb6fe97d0b483032ff1c7,
// receive lpToken 3CRV 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490
// deposit 3crv to convex booster 0xF403C135812408BFbE8713b5A23a04b3D48AAE31, pool id is 9

// harvest will get reward from rewards contract 0x689440f2ff927e1f24c72f1087e1faf471ece1c8

contract StrategyConvex3Pool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public slippage = 500;
    uint256 public constant SLIPPAGE_DENOMINATOR = 10000;

    address public constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public constant uniswap = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address public constant cvx = address(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B); // convex CVX erc20 token
    address public pool; // curve 3pool
    address public lpToken; // 3crv
    address public convex;
    address public convexRewards;
    uint256 public convexPoolId; // poolid in convex booster

    uint8 public supplyTokenIndexInPool;
    uint256 public decimalDiff;

    constructor(
        address _controller,
        address _supplyToken,
        uint8 _supplyTokenDecimal,
        uint8 _supplyTokenIndexIn3Pool,
        address _3pool,
        address _3crv,
        address _convex,
        address _convexRewards,
        uint256 _convexPoolId
    ) AbstractStrategy(_controller, _supplyToken) {
        pool = _3pool;
        lpToken = _3crv;
        convex = _convex;
        convexRewards = _convexRewards;
        convexPoolId = _convexPoolId;
        supplyTokenIndexInPool = _supplyTokenIndexIn3Pool;
        decimalDiff = PRICE_DECIMALS / 10**_supplyTokenDecimal; // curve treats supply tokens as they have 18 decimals but tokens like USDC and USDT actually have 6 decimals
    }

    function getAssetAmount() internal view override returns (uint256) {
        uint256 lpTokenBalance = IConvexRewards(convexRewards).balanceOf(address(this));
        return ((lpTokenBalance * ICurveFi(pool).get_virtual_price()) / decimalDiff) / PRICE_DECIMALS;
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        // pull fund from controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        uint256 obtainedLpTokens = _addLiquidity(_buyAmount);

        // deposit LP tokens to convex booster
        IERC20(lpToken).safeIncreaseAllowance(convex, obtainedLpTokens);
        IConvex(convex).deposit(convexPoolId, obtainedLpTokens, true);

        uint256 obtainedUnderlyingAsset = ((obtainedLpTokens * ICurveFi(pool).get_virtual_price()) / decimalDiff) /
            PRICE_DECIMALS;
        return obtainedUnderlyingAsset;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        uint256 sellLpTokens = (_sellAmount * PRICE_DECIMALS * decimalDiff) / ICurveFi(pool).get_virtual_price();
        // get lpToken back, leave claim to harvest
        IConvexRewards(convexRewards).withdrawAndUnwrap(sellLpTokens, false);

        // remove liquidity from pool to get supplyToken back
        uint256 minAmountFromSell = (_sellAmount * (SLIPPAGE_DENOMINATOR - slippage)) / SLIPPAGE_DENOMINATOR;
        uint256 balanceBeforeSell = IERC20(supplyToken).balanceOf(address(this));
        ICurveFi(pool).remove_liquidity_one_coin(sellLpTokens, int8(supplyTokenIndexInPool), minAmountFromSell);
        uint256 obtainedSupplyToken = IERC20(supplyToken).balanceOf(address(this)) - balanceBeforeSell;
        IERC20(supplyToken).safeTransfer(msg.sender, obtainedSupplyToken);

        return obtainedSupplyToken;
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
    function harvest() external override onlyOwnerOrController {
        IConvexRewards(convexRewards).getReward(); // receive both crv and cvx
        uint256 originalBalance = IERC20(supplyToken).balanceOf(address(this));
        uint256 crvBalance = IERC20(crv).balanceOf(address(this));
        uint256 cvxBalance = IERC20(cvx).balanceOf(address(this));

        if (crvBalance > 0) {
            // Sell CRV for more supply token
            IERC20(crv).safeIncreaseAllowance(uniswap, crvBalance);
            address[] memory path = new address[](3);
            path[0] = crv;
            path[1] = weth;
            path[2] = supplyToken;

            IUniswapV2Router02(uniswap).swapExactTokensForTokens(
                crvBalance,
                uint256(0),
                path,
                address(this),
                block.timestamp + 1800
            );
        }
        if (cvxBalance > 0) {
            IERC20(cvx).safeIncreaseAllowance(uniswap, cvxBalance);
            address[] memory path = new address[](3);
            path[0] = cvx;
            path[1] = weth;
            path[2] = supplyToken;

            IUniswapV2Router02(uniswap).swapExactTokensForTokens(
                cvxBalance,
                uint256(0),
                path,
                address(this),
                block.timestamp + 1800
            );
        }

        // Re-invest supply token to obtain more lpToken
        uint256 obtainedAssetAmount = IERC20(supplyToken).balanceOf(address(this)) - originalBalance;
        if (obtainedAssetAmount > 0) {
            uint256 obtainedLpToken = _addLiquidity(obtainedAssetAmount);
            // deposit LP tokens to convex booster
            IERC20(lpToken).safeIncreaseAllowance(convex, obtainedLpToken);
            IConvex(convex).deposit(convexPoolId, obtainedLpToken, true);
        }
    }

    function setSlippage(uint256 _slippage) external onlyOwner {
        slippage = _slippage;
    }
}