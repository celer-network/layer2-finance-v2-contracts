// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../../interfaces/IWETH.sol";
import "../base/AbstractStrategy.sol";
import "../uniswap-v2/interfaces/IUniswapV2Pair.sol";
import "../uniswap-v2/interfaces/IUniswapV2Router02.sol";
import "./libraries/SushiswapLibrary.sol";
import "./interfaces/IMasterChef.sol";

/**
 * Deposit one token, exchange half of them to another token using SushiSwap, and then deposit the pair
 * into SushiSwap for liquidity farming.
 */
contract StrategySushiswap is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of token to be paired
    address public pairToken;
    address public sushiswap;
    address public masterChef;
    address public sushi;
    uint256 public maxSlippage;
    uint256 public maxOneDeposit;
    // The id of the pool to farm Sushi
    int256 public poolId;
    uint256 public lpAmtInPool;

    constructor(
        address _controller,
        address _supplyToken,
        address _pairToken,
        address _sushiswap,
        address _masterChef,
        address _sushi,
        uint256 _maxSlippage,
        uint256 _maxOneDeposit,
        int256 _poolId
    ) AbstractStrategy(_controller, _supplyToken) {
        pairToken = _pairToken;
        sushiswap = _sushiswap;
        masterChef = _masterChef;
        sushi = _sushi;
        maxSlippage = _maxSlippage;
        maxOneDeposit = _maxOneDeposit;
        poolId = _poolId;
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
        IUniswapV2Pair pair = IUniswapV2Pair(
            SushiswapLibrary.pairFor(IUniswapV2Router02(sushiswap).factory(), _supplyToken, _pairToken)
        );
        uint256 myLiquidity = pair.balanceOf(address(this)) + lpAmtInPool;
        if (myLiquidity == 0) {
            return IERC20(supplyToken).balanceOf(address(this)); // should include the assets not yet adjusted
        }

        uint256 totalSupply = pair.totalSupply();
        (address token0, ) = SushiswapLibrary.sortTokens(_supplyToken, _pairToken);
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        if (_supplyToken != token0) {
            (reserve0, reserve1) = (reserve1, reserve0);
        }
        uint256 myReserve0 = (myLiquidity * reserve0) / totalSupply;
        uint256 myReserve1 = (myLiquidity * reserve1) / totalSupply;
        uint256 myReserve1Out = SushiswapLibrary.getAmountOut(myReserve1, reserve1, reserve0);

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
            address _sushiswap = sushiswap;

            IUniswapV2Pair pair = IUniswapV2Pair(
                SushiswapLibrary.pairFor(IUniswapV2Router02(_sushiswap).factory(), _supplyToken, _pairToken)
            );
            uint256 lpInMyAddress = pair.balanceOf(address(this));
            uint256 toSellLiquidity = ((lpInMyAddress + lpAmtInPool) * amtFromUniswap) /
                (getAssetAmount() - balanceBeforeSell);
            if (toSellLiquidity > lpInMyAddress) {
                assert(poolId != -1);
                uint256 withdrawAmt = toSellLiquidity - lpInMyAddress;
                lpAmtInPool -= withdrawAmt;
                IMasterChef(masterChef).withdraw(uint256(poolId), withdrawAmt);
            }

            pair.approve(_sushiswap, toSellLiquidity);
            (uint256 amountS, uint256 amountP) = IUniswapV2Router02(_sushiswap).removeLiquidity(
                _supplyToken,
                _pairToken,
                toSellLiquidity,
                0,
                0,
                address(this),
                block.timestamp + 1800
            );

            IERC20(_pairToken).safeIncreaseAllowance(_sushiswap, amountP);
            address[] memory paths = new address[](2);
            paths[0] = _pairToken;
            paths[1] = _supplyToken;
            IUniswapV2Router02(_sushiswap).swapExactTokensForTokens(
                amountP,
                ((amtFromUniswap - amountS) * (1e18 - maxSlippage)) / 1e18,
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
        address _sushiswap = sushiswap;

        uint256 balance = IERC20(_supplyToken).balanceOf(address(this));
        require(balance > 0, "StrategyUniswapV2: no balance");

        uint256 toBuy = min(balance, maxOneDeposit);
        uint256 half = toBuy / 2;
        IUniswapV2Pair pair = IUniswapV2Pair(
            SushiswapLibrary.pairFor(IUniswapV2Router02(_sushiswap).factory(), _supplyToken, _pairToken)
        );

        // swap half for pair token
        {
            IERC20(_supplyToken).safeIncreaseAllowance(_sushiswap, half);
            address[] memory paths = new address[](2);
            paths[0] = _supplyToken;
            paths[1] = _pairToken;

            (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
            uint256 expectOut = SushiswapLibrary.getAmountOut(half, reserve0, reserve1);

            IUniswapV2Router02(_sushiswap).swapExactTokensForTokens(
                half,
                (expectOut * (1e18 - maxSlippage)) / 1e18,
                paths,
                address(this),
                block.timestamp + 1800
            );
        }

        uint256 swappedPairTokenAmt = IERC20(_pairToken).balanceOf(address(this));
        IERC20(_supplyToken).safeIncreaseAllowance(_sushiswap, half);
        IERC20(_pairToken).safeIncreaseAllowance(_sushiswap, swappedPairTokenAmt);
        IUniswapV2Router02(_sushiswap).addLiquidity(
            _supplyToken,
            _pairToken,
            half,
            swappedPairTokenAmt,
            0,
            0,
            address(this),
            block.timestamp + 1800
        );

        // deposit into pool for Sushi farming
        if (poolId != -1) {
            uint256 lpInMyAddress = pair.balanceOf(address(this));
            pair.approve(masterChef, lpInMyAddress);
            IMasterChef(masterChef).deposit(uint256(poolId), lpInMyAddress);
            lpAmtInPool += lpInMyAddress;
        }
    }

    function harvest() external override {
        address _supplyToken = supplyToken;
        address _pairToken = pairToken;
        address _sushiswap = sushiswap;
        // swap the left pair token in my address back to supply token
        uint256 balance = IERC20(_pairToken).balanceOf(address(this));
        if (balance > 0) {
            IERC20(_pairToken).safeIncreaseAllowance(_sushiswap, balance);
            address[] memory paths = new address[](2);
            paths[0] = _pairToken;
            paths[1] = _supplyToken;

            IUniswapV2Router02(_sushiswap).swapExactTokensForTokens(
                balance,
                uint256(0),
                paths,
                address(this),
                block.timestamp + 1800
            );
        }

        if (poolId != -1) {
            IMasterChef(masterChef).withdraw(uint256(poolId), 0); // to trigger sushi harvest only
            uint256 sushiBalance = IERC20(sushi).balanceOf(address(this));
            if (sushiBalance > 0) {
                // Sell Sushi token for obtain more supplying token(e.g. USDC)
                IERC20(sushi).safeIncreaseAllowance(_sushiswap, sushiBalance);

                address[] memory paths = new address[](2);
                paths[0] = sushi;
                paths[1] = supplyToken;

                IUniswapV2Router02(_sushiswap).swapExactTokensForTokens(
                    sushiBalance,
                    uint256(0),
                    paths,
                    address(this),
                    block.timestamp + 1800
                );
            }
        }
    }

    function setMaxOneDeposit(uint256 _maxOneDeposit) external onlyController {
        maxOneDeposit = _maxOneDeposit;
    }

    function setMaxSlippage(uint256 _maxSlippage) external onlyController {
        maxSlippage = _maxSlippage;
    }
}
