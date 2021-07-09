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

    address public pool; // swap pool
    address public gauge; // Curve gauge
    address public mintr; // Curve minter
    address public uniswap; // UniswapV2
    address public crv; // CRV token
    address public weth;
    uint8 public supplyTokenIndexInPool = 0; // ETH - 0, Other - 1

    constructor(
        address _controller,
        address _lpToken,
        address _supplyToken,
        uint8 _supplyTokenIndexInPool,
        address _pool,
        address _gauge,
        address _mintr,
        address _crv,
        address _weth,
        address _uniswap
    ) AbstractStrategy(_controller, _supplyToken, _lpToken) {
        supplyTokenIndexInPool = _supplyTokenIndexInPool;
        pool = _pool;
        gauge = _gauge;
        mintr = _mintr;
        crv = _crv;
        weth = _weth;
        uniswap = _uniswap;
    }

    function getLpTokenPrice() public view override returns (uint256) {
        return ICurveFi(pool).get_virtual_price();
    }

    function buy(uint256 _buyAmount, uint256 _minLpTokenFromBuy) internal override returns (uint256) {
        // pull fund from controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // add liquidity in pool
        uint256[3] memory amounts;
        amounts[supplyTokenIndexInPool] = _buyAmount;
        ICurveFi(pool).add_liquidity(amounts, _minLpTokenFromBuy);
        uint256 obtainedLpTokens = IERC20(lpToken).balanceOf(address(this));

        // deposit bought LP tokens to curve gauge to farm CRV
        IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpTokens);
        IGauge(gauge).deposit(obtainedLpTokens);

        return obtainedLpTokens;
    }

    function sell(uint256 _sellLpTokens, uint256 _minAmountFromSell) internal override returns (uint256) {
        // unstake from needed lpTokens for sell from gauge
        IGauge(gauge).withdraw(_sellLpTokens);

        // remove liquidity from pool
        ICurveFi(pool).remove_liquidity_one_coin(_sellLpTokens, int8(supplyTokenIndexInPool), _minAmountFromSell);
        uint256 obtainedSupplyToken = address(this).balance;

        return obtainedSupplyToken;
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
            path[2] = supplyToken;

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
            uint256[3] memory amounts;
            amounts[supplyTokenIndexInPool] = obtainedAssetAmount;
            ICurveFi(pool).add_liquidity(amounts, minMintAmount);

            // Stake lpToken in Gauge to farm more CRV
            uint256 obtainedLpToken = IERC20(lpToken).balanceOf(address(this));
            IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpToken);
            IGauge(gauge).deposit(obtainedLpToken);
        }
    }
}
