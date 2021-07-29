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
            return IERC20(supplyToken).balanceOf(address(this)); // should include the assets not yet adjusted
        }
        
        uint256 totalSupply = pair.totalSupply();
        (address token0,) = UniswapV2Library.sortTokens(_supplyToken, _pairToken);
        (uint reserve0, uint reserve1,) = pair.getReserves();
        if (_supplyToken != token0) {
            (reserve0, reserve1) = (reserve1, reserve0);
        }
        uint myReserve0 = myLiquidity * reserve0 / totalSupply;
        uint myReserve1 = myLiquidity * reserve1 / totalSupply;
        uint myReserve1Out = UniswapV2Library.getAmountOut(myReserve1, reserve1, reserve0);
        
        return myReserve0 + myReserve1Out + IERC20(supplyToken).balanceOf(address(this)); // should include the assets not yet adjusted        
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        // Pull supplying token(e.g. USDC, USDT) from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // do virtual buy here, actual buy is done in adjust method        
        return _buyAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        address _supplyToken = supplyToken;
        uint256 balanceBeforeSell = IERC20(_supplyToken).balanceOf(address(this));
        uint256 amtFromUniswap;

        if (balanceBeforeSell < _sellAmount) {
            amtFromUniswap = _sellAmount - balanceBeforeSell;
        } 

        if (amtFromUniswap > 0) {
            address _pairToken = pairToken;
            address _uniswap = uniswap;
            
            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(IUniswapV2(_uniswap).factory(), _supplyToken, _pairToken));
            uint256 toSellLiquidity = pair.balanceOf(address(this)) * amtFromUniswap / (getAssetAmount() - balanceBeforeSell);
            pair.approve(_uniswap, toSellLiquidity);
            (uint amountS, uint amountP) = IUniswapV2(_uniswap).removeLiquidity(_supplyToken, _pairToken, toSellLiquidity, 
                0, 0, address(this), block.timestamp + 1800);

            IERC20(_pairToken).safeIncreaseAllowance(uniswap, amountP);
            address[] memory paths = new address[](2);
            paths[0] = _pairToken;
            paths[1] = _supplyToken;
            IUniswapV2(_uniswap).swapExactTokensForTokens(
                amountP,
                (amtFromUniswap - amountS) * (1e18 - maxSlippage) / 1e18,
                paths,
                address(this),
                block.timestamp + 1800
            );

            _sellAmount = IERC20(_supplyToken).balanceOf(address(this));
        }

        IERC20(_supplyToken).safeTransfer(msg.sender, _sellAmount);
        return _sellAmount;
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        return x <= y ? x : y;
    }

    function adjust() external onlyController {
        address _supplyToken = supplyToken;
        address _pairToken = pairToken;
        address _uniswap = uniswap;

        uint256 balance = IERC20(_supplyToken).balanceOf(address(this));
        require(balance > 0, "StrategyUniswapV2: no balance");

        uint256 toBuy = min(balance, maxOneDeposit);
        uint256 half = toBuy / 2;
        
        // swap half for pair token
        {
            IERC20(_supplyToken).safeIncreaseAllowance(_uniswap, half);
            address[] memory paths = new address[](2);
            paths[0] = _supplyToken;
            paths[1] = _pairToken;

            (uint reserve0, uint reserve1) = UniswapV2Library.getReserves(IUniswapV2(_uniswap).factory(), _supplyToken, _pairToken);
            uint256 expectOut = UniswapV2Library.getAmountOut(half, reserve0, reserve1);

            IUniswapV2(_uniswap).swapExactTokensForTokens(
                half,
                expectOut * (1e18 - maxSlippage) / 1e18,
                paths,
                address(this),
                block.timestamp + 1800
            );
        }

        uint256 swappedPairTokenAmt = IERC20(_pairToken).balanceOf(address(this));
        IERC20(_supplyToken).safeIncreaseAllowance(_uniswap, half);
        IERC20(_pairToken).safeIncreaseAllowance(_uniswap, swappedPairTokenAmt);
        IUniswapV2(_uniswap).addLiquidity(_supplyToken, _pairToken, half, swappedPairTokenAmt, 0, 0, address(this), block.timestamp + 1800);
    }

    function harvest() external override {
        // Not supported
        // TODO: consider to swap the left pair token in my address back to supply token
    }

    function setMaxOneDeposit(uint256 _maxOneDeposit) external onlyController {
        maxOneDeposit = _maxOneDeposit;
    }

    function setMaxSlippage(uint256 _maxSlippage) external onlyController {
        maxSlippage = _maxSlippage;
    }
}
