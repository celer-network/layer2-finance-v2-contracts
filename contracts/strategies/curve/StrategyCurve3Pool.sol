// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/IWETH.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/uniswap/IUniswapV2.sol";
import "../interfaces/curve/ICurveFi.sol";
import "../interfaces/curve/IGauge.sol";
import "../interfaces/curve/IMintr.sol";

contract StrategyCurveEthPool is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    uint256 constant MAX_INT = 2**256 - 1;

    address public controller;

    // contract addresses
    address public pool; // swap pool
    address public gauge; // Curve gauge
    address public mintr; // Curve minter
    address public uniswap; // UniswapV2

    // supply token params
    uint8 public supplyTokenIndexInPool = 0; // ETH - 0, Other - 1
    uint8 public supplyTokenDecimals;

    // token addresses
    address public supplyToken;
    address public lpToken; // LP token
    address public crv; // CRV token
    address public weth; // WETH token

    // slippage tolerance settings
    uint256 public constant DENOMINATOR = 10000;
    uint256 public slippage = 500;

    // asset and share tracking
    uint256 assetAmount;
    uint256 shares;

    constructor(
        address _controller,
        uint8 _supplyTokenIndexInPool,
        uint8 _supplyTokenDecimals,
        address _pool,
        address _supplyToken,
        address _lpToken,
        address _gauge,
        address _mintr,
        address _crv,
        address _weth,
        address _uniswap
    ) {
        controller = _controller;
        supplyTokenIndexInPool = _supplyTokenIndexInPool;
        supplyTokenDecimals = _supplyTokenDecimals;
        pool = _pool;
        supplyToken = _supplyToken;
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
        uint256 _minSharesFromBuy,
        uint256 _sellShares,
        uint256 _minAmountFromSell
    ) external override onlyController returns (uint256, uint256) {
        require(msg.sender == controller, "Not controller");
        require(shares >= _sellShares, "not enough shares to sell");

        uint256 amountFromSell;
        uint256 sharesFromBuy;
        uint256 lpTokenPrice = ICurveFi(pool).get_virtual_price();

        if (assetAmount == 0 || shares == 0) {
            assetAmount = _buyAmount;
            shares = _buyAmount;
            sharesFromBuy = _buyAmount;
        } else {
            amountFromSell = _sellShares.mul(assetAmount).div(shares);
            sharesFromBuy = _buyAmount.mul(shares).div(assetAmount);
            assetAmount = assetAmount.add(_buyAmount).sub(amountFromSell);
            shares = shares.add(sharesFromBuy).sub(_sellShares);
        }

        require(sharesFromBuy >= _minSharesFromBuy, "failed min shares from buy");
        require(amountFromSell >= _minAmountFromSell, "failed min amount from sell");

        if (amountFromSell < _buyAmount) {
            uint256 buyAmount = _buyAmount - amountFromSell;
            uint256 minLpTokenFromBuy = buyAmount.mul(lpTokenPrice).div(1e18).mul(DENOMINATOR.sub(slippage)).div(
                DENOMINATOR
            );
            _buy(buyAmount, minLpTokenFromBuy);
        } else if (amountFromSell > _buyAmount) {
            uint256 sellShares = _sellShares - sharesFromBuy;
            uint256 minAmountFromSell = sellShares.mul(1e18).div(lpTokenPrice).mul(DENOMINATOR.sub(slippage)).div(
                DENOMINATOR
            );
            _sell(sellShares, minAmountFromSell);
        }

        return (sharesFromBuy, amountFromSell);
    }

    function _buy(uint256 _buyAmount, uint256 _minLpTokenFromBuy) private {
        // pull fund from controller
        IERC20(weth).safeTransferFrom(msg.sender, address(this), _buyAmount);
        IWETH(weth).withdraw(_buyAmount);

        // add liquidity in pool
        uint256[3] memory amounts;
        amounts[supplyTokenIndexInPool] = _buyAmount;
        IERC20(lpToken).safeIncreaseAllowance(pool, _buyAmount);
        ICurveFi(pool).add_liquidity(amounts, _minLpTokenFromBuy);
        uint256 obtainedLpTokens = IERC20(lpToken).balanceOf(address(this));

        // deposit bought LP tokens to curve gauge to farm CRV
        IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpTokens);
        IGauge(gauge).deposit(obtainedLpTokens);

        emit Buy(_buyAmount, obtainedLpTokens);
    }

    function _sell(uint256 _sellShares, uint256 _minAmount) private {
        // pull shares from controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _sellShares);

        // remove liquidity from pool
        ICurveFi(pool).remove_liquidity_one_coin(_sellShares, int8(supplyTokenIndexInPool), _minAmount);

        uint256 ethBalance = address(this).balance;

        // wrap ETH and send back to controller
        IWETH(supplyToken).deposit{value: ethBalance}();
        IERC20(supplyToken).safeTransfer(msg.sender, ethBalance);

        emit Sell(_sellShares, ethBalance);
    }

    function syncPrice() external view override returns (uint256) {
        if (shares == 0) {
            if (assetAmount == 0) {
                return 1e18;
            }
            return MAX_INT;
        }
        return (assetAmount * 1e18) / shares;
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
                block.timestamp.add(1800)
            );

            // Re-invest supply token to obtain more lpToken
            uint256 obtainedAssetAmount = address(this).balance;
            uint256 minMintAmount = obtainedAssetAmount
            .mul(1e18)
            .div(ICurveFi(pool).get_virtual_price())
            .mul(DENOMINATOR.sub(slippage))
            .div(DENOMINATOR);
            uint256[3] memory amounts;
            amounts[supplyTokenIndexInPool] = obtainedAssetAmount;
            IERC20(lpToken).safeIncreaseAllowance(pool, obtainedAssetAmount);
            ICurveFi(pool).add_liquidity(amounts, minMintAmount);

            // Stake lpToken in Gauge to farm more CRV
            uint256 obtainedLpToken = IERC20(lpToken).balanceOf(address(this));
            IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedLpToken);
            IGauge(gauge).deposit(obtainedLpToken);

            // add newly obtained supply token amount to asset amount
            assetAmount = assetAmount.add(obtainedAssetAmount);
        }
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }
}
