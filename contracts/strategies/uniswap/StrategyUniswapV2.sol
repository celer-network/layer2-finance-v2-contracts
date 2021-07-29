// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./UniswapV2Library.sol";
import "../AbstractStrategy.sol";
import "../interfaces/uniswap/IUniswapV2.sol";
import "../interfaces/uniswap/IUniswapV2Pair.sol";
import "../../interfaces/IWETH.sol";

/**
 * Deposit one token, exchange half of them to another token using uniswap, and then deposit the pair
 * into uniswap V2 for liquidity farming. 
 */
contract StrategyUniswapV2 is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of token to be paired
    address public pairToken;
    address public uniswap;
    uint256 public maxSlippage;
    uint256 public maxOneDeposit;

    constructor(
        address _controller,
        address _supplyToken,
        address _pairToken,
        address _uniswap,
        uint256 _maxSlippage,
        uint256 _maxOneDeposit
    ) AbstractStrategy(_controller, _supplyToken) {
        pairToken = _pairToken;
        uniswap = _uniswap;
        maxSlippage = _maxSlippage;
        maxOneDeposit = _maxOneDeposit;
    }

    /**
     * @dev Require that the caller must be an EOA account to avoid flash loans.
     */
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Not EOA");
        _;
    }

    function getAssetAmount() internal view override returns (uint256) {
        address _supplyToken = supplyToken;
        address _pairToken = pairToken;
        IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(IUniswapV2(uniswap).factory(), _supplyToken, _pairToken));
        uint256 myLiquidity = pair.balanceOf(address(this));
        if (myLiquidity == 0) {
            return 0;
        }
        uint256 totalSupply = pair.totalSupply();
        uint256 estimateAssetAmt;
        {
            (address token0,) = UniswapV2Library.sortTokens(_supplyToken, _pairToken);
            (uint reserve0, uint reserve1,) = pair.getReserves();
            if (_supplyToken != token0) {
                (reserve0, reserve1) = (reserve1, reserve0);
            }
            uint myReserve0 = myLiquidity * reserve0 / totalSupply;
            uint myReserve1 = myLiquidity * reserve1 / totalSupply;
            uint myReserve1Out = UniswapV2Library.getAmountOut(myReserve1, reserve1, reserve0);
            estimateAssetAmt = myReserve0 + myReserve1Out + IERC20(supplyToken).balanceOf(address(this)); // should include the assets not yet adjusted
        }
        
        return estimateAssetAmt;
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        // Pull supplying token(e.g. USDC, USDT) from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // do virtual buy here, actual buy is done in adjust method        
        return _buyAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        uint256 balanceBeforeSell = IERC20(supplyToken).balanceOf(address(this));
        uint256 remainAmt = _sellAmount;

        if (balanceBeforeSell != 0) {
            IERC20(supplyToken).safeTransfer(msg.sender, min(balanceBeforeSell, remainAmt));
            if (balanceBeforeSell < remainAmt) {
                remainAmt -= balanceBeforeSell;
            } else {
                remainAmt = 0;
            }
        }

        if (remainAmt > 0) {
            address _supplyToken = supplyToken;
            address _pairToken = pairToken;
            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(IUniswapV2(uniswap).factory(), _supplyToken, _pairToken));
            uint256 myLiquidity = pair.balanceOf(address(this));
            uint256 myEstAmount = getAssetAmount(); 
            (uint amountS, uint amountP) = IUniswapV2(uniswap).removeLiquidity(_supplyToken, _pairToken, myLiquidity * remainAmt / myEstAmount, 
                0, 0, address(this), block.timestamp + 1800);
            

            IERC20(_pairToken).safeIncreaseAllowance(uniswap, amountP);
            address[] memory paths = new address[](3);
            paths[0] = _pairToken;
            paths[1] = _supplyToken;

            uint[] memory amounts = IUniswapV2(uniswap).swapExactTokensForTokens(
                amountP,
                (remainAmt - amountS) * (1e18 - maxSlippage) / 1e18,
                paths,
                address(this),
                block.timestamp + 1800
            );
            uint256 soldAmount = amountS + amounts[0];
            IERC20(supplyToken).safeTransfer(msg.sender, soldAmount);

            _sellAmount = balanceBeforeSell + soldAmount;
        }
        
        return _sellAmount;
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        return x <= y ? x : y;
    }

    function adjust() external onlyController {
        address _supplyToken = supplyToken;
        address _pairToken = pairToken;
        uint256 balance = IERC20(_supplyToken).balanceOf(address(this));
        require(balance > 0, "StrategyUniswapV2: no balance");

        uint256 toBuy = min(balance, maxOneDeposit);
        uint256 half = toBuy / 2;
        uint256 swappedPairTokenAmt;
        
        // swap half for pair token
        {
            IERC20(_supplyToken).safeIncreaseAllowance(uniswap, half);
            address[] memory paths = new address[](3);
            paths[0] = _supplyToken;
            paths[1] = _pairToken;

            (uint reserve0, uint reserve1) = UniswapV2Library.getReserves(IUniswapV2(uniswap).factory(), _supplyToken, _pairToken);
            uint256 expectOut = UniswapV2Library.getAmountOut(half, reserve0, reserve1);

            uint[] memory amounts = IUniswapV2(uniswap).swapExactTokensForTokens(
                half,
                expectOut * (1e18 - maxSlippage) / 1e18,
                paths,
                address(this),
                block.timestamp + 1800
            );
            swappedPairTokenAmt = amounts[0];
        }

        IERC20(_supplyToken).safeIncreaseAllowance(uniswap, half);
        IERC20(_pairToken).safeIncreaseAllowance(uniswap, swappedPairTokenAmt);
        IUniswapV2(uniswap).addLiquidity(_supplyToken, _pairToken, half, swappedPairTokenAmt, 0, 0, address(this), block.timestamp + 1800);
    }

    function harvest() external override {
        // Not supported
    }

    function setMaxOneDeposit(uint256 _maxOneDeposit) external onlyController {
        maxOneDeposit = _maxOneDeposit;
    }

    function setMaxSlippage(uint256 _maxSlippage) external onlyController {
        maxSlippage = _maxSlippage;
    }
}
