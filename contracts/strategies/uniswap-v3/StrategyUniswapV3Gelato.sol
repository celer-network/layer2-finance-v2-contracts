// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "../base/AbstractStrategy.sol";
import "./interfaces/gelato/IGUniPool.sol";
import "./interfaces/gelato/IGUniResolver.sol";
import "./interfaces/gelato/IGUniRouter.sol";
import "./libraries/FullMath.sol";

/**
 * Deposits ERC20 token into Gelato Uniswap V3 Pool. Holds G-UNI LP tokens.
 */
contract StrategyUniswapV3Gelato is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of the G-UNI pool
    address public immutable gUniPoolAddress;
    // The address of the G-UNI resolver
    address public immutable gUniResolver;
    // The address of the G-UNI router
    address public immutable gUniRouter;
    // The address of the Uniswap V3 router
    address public immutable swapRouter;
    // Whether the supply token is token0
    bool public immutable supply0;

    uint256 public slippage = 2000;
    uint256 public constant SLIPPAGE_DENOMINATOR = 10000;

    constructor(
        address _supplyToken,
        address _gUniPool,
        address _gUniResolver,
        address _gUniRouter,
        address _swapRouter,
        address _controller
    ) AbstractStrategy(_controller, _supplyToken) {
        gUniPoolAddress = _gUniPool;
        gUniResolver = _gUniResolver;
        gUniRouter = _gUniRouter;
        swapRouter = _swapRouter;

        supply0 = (_supplyToken == IGUniPool(_gUniPool).token0());
    }

    function getAssetAmount() public view override returns (uint256) {
        IGUniPool gUniPool = IGUniPool(gUniPoolAddress);
        (uint256 amount0, uint256 amount1) = IGUniRouter(gUniRouter).getUnderlyingBalances(
            gUniPool,
            address(this),
            gUniPool.balanceOf(address(this))
        );
        if (!supply0) {
            (amount0, amount1) = (amount1, amount0);
        }
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(gUniPool.pool()).slot0();
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * PRICE_DECIMALS) >> (96 * 2);
        return amount0 + (amount1 * PRICE_DECIMALS) / price;
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        if (_buyAmount == 0) {
            return 0;
        }

        uint256 originalAssetAmount = getAssetAmount();

        // Pull supply token from Controller.
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // Deposit supply token to the G-Uni pool.
        IGUniPool gUniPool = IGUniPool(gUniPoolAddress);
        IERC20(supplyToken).safeIncreaseAllowance(gUniRouter, _buyAmount);
        uint256 amount0In = _buyAmount;
        uint256 amount1In = 0;
        if (!supply0) {
            (amount0In, amount1In) = (amount1In, amount0In);
        }
        (bool zeroForOne, uint256 swapAmount, uint160 swapThreshold) = IGUniResolver(gUniResolver).getRebalanceParams(
            gUniPool,
            amount0In,
            amount1In,
            uint16(slippage)
        );
        // TODO: Check price
        IGUniRouter(gUniRouter).rebalanceAndAddLiquidity(
            gUniPool,
            amount0In,
            amount1In,
            zeroForOne,
            swapAmount,
            swapThreshold,
            0,
            0,
            address(this)
        );

        uint256 newAssetAmount = getAssetAmount();
        return newAssetAmount - originalAssetAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        if (_sellAmount == 0) {
            return 0;
        }

        uint256 balanceBeforeSell = IERC20(supplyToken).balanceOf(address(this));

        // Withdraw supply token from the G-Uni pool.
        IGUniPool gUniPool = IGUniPool(gUniPoolAddress);
        uint256 amount0Max = _sellAmount;
        uint256 amount1Max = 0;
        if (!supply0) {
            (amount0Max, amount1Max) = (amount1Max, amount0Max);
        }
        uint256 burnAmount = FullMath.mulDiv(_sellAmount, gUniPool.balanceOf(address(this)), getAssetAmount());
        IERC20(gUniPoolAddress).safeIncreaseAllowance(gUniRouter, burnAmount);
        // TODO: Check price
        (uint256 removedAmount0, uint256 removedAmount1, ) = gUniPool.burn(burnAmount, address(this));

        // Swap to supply token if necessary
        if ((!supply0 && removedAmount0 > 0) || (supply0 && removedAmount1 > 0)) {
            address tokenIn = gUniPool.token1();
            address tokenOut = gUniPool.token0();
            uint256 amountIn = removedAmount1;
            if (!supply0) {
                (tokenIn, tokenOut) = (tokenOut, tokenIn);
                amountIn = removedAmount0;
            }
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: IUniswapV3Pool(gUniPool.pool()).fee(),
                recipient: address(this),
                deadline: block.timestamp + 1800,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            IERC20(tokenIn).safeIncreaseAllowance(swapRouter, amountIn);
            ISwapRouter(swapRouter).exactInputSingle(params);
        }
        // Transfer supply token to Controller
        uint256 balanceAfterSell = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, balanceAfterSell);

        return balanceAfterSell - balanceBeforeSell;
    }

    function setSlippage(uint256 _slippage) external onlyOwner {
        slippage = _slippage;
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](1);
        protected[0] = gUniPoolAddress;
        return protected;
    }
}
