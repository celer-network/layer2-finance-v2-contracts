// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IStrategy.sol";

contract StrategyCurve3Pool is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public controller;

    // contract addresses
    address public triPool; // Curve 3 token swap pool
    address public gauge; // Curve gauge
    address public mintr; // Curve minter
    address public uniswap; // UniswapV2

    // supply token params
    uint8 public supplyTokenDecimals;
    uint8 public supplyTokenIndexInPool = 0;

    // token addresses
    address public supplyToken;
    address public lpToken; // LP token (triCrv)
    address public crv;
    address public weth;

    // slippage tolerance settings
    uint256 public constant DENOMINATOR = 10000;
    uint256 public slippage = 500;

    constructor(
        address _controller,
        address _supplyToken,
        uint8 _supplyTokenDecimals,
        uint8 _supplyTokenIndexInPool,
        address _triPool,
        address _lpToken,
        address _gauge,
        address _mintr,
        address _crv,
        address _weth,
        address _uniswap
    ) {
        controller = _controller;
        supplyToken = _supplyToken;
        supplyTokenDecimals = _supplyTokenDecimals;
        supplyTokenIndexInPool = _supplyTokenIndexInPool;
        triPool = _triPool;
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
        return asset;
    }

    function aggregateOrders(
        uint256 _buyAmount, // ETH
        uint256 _minSharesToBuy,
        uint256 _sellShares, // LP Token
        uint256 _minAmountFromSell
    ) external override onlyController returns (uint256, uint256) {
        require(msg.sender == controller, "Not controller");

        uint256 price = ICurveFi(triPool).get_virtual_price();
        uint256 amountDerivedFromSellShares =
            _sellShares.div(1e18).div(1e18).div(10**(18 - supplyTokenDecimals)).mul(price); // amount to be obtained from selling LP Token
        uint256 sharesDerivedFromBuyAmount =
            _buyAmount.mul(1e18).mul(1e18).mul(10**(18 - supplyTokenDecimals)).div(price); // LP Token to get obtained from buying with supply token

        uint256 sharesBought; // bought shares from share sellers and/or curvefi
        uint256 amountSoldFor; // ETH for which the sellers' shares are sold

        if (sharesDerivedFromBuyAmount > _sellShares) {
            // LP Token amount to sell in this batch can't cover the share amount of LP tokens people want to buy
            // therefore we need buy more LP Tokens to cover the demand for more LP Tokens.
            uint256 buyAmount = _buyAmount - amountDerivedFromSellShares;
            IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), buyAmount);
            uint256[2] memory amounts;
            amounts[supplyTokenIndexInPool] = buyAmount;
            ICurveFi(triPool).add_liquidity{value: buyAmount}(
                amounts,
                sharesDerivedFromBuyAmount.mul(DENOMINATOR.sub(slippage)).div(DENOMINATOR)
            );
            uint256 obtainedShares = IERC20(lpToken).balanceOf(address(this));
            // deposit bought LP tokens to curve gauge to farm CRV
            IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedShares);
            IGauge(gauge).deposit(obtainedShares);
            sharesBought = _sellShares + obtainedShares;
            amountSoldFor = amountDerivedFromSellShares;
            emit Buy(buyAmount, obtainedShares);
        } else if (sharesDerivedFromBuyAmount < _sellShares) {
            // LP Token to be obtained from buying in this batch can't cover the LP Token amount people want to sell
            // therefore we need sell more LP Tokens to cover the need for more ETH.
            uint256 sellShares = _sellShares - sharesDerivedFromBuyAmount;
            IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), sellShares);
            ICurveFi(triPool).remove_liquidity_one_coin(
                sellShares,
                supplyTokenIndexInPool,
                amountDerivedFromSellShares.mul(DENOMINATOR.sub(slippage)).div(DENOMINATOR)
            );
            uint256 ethBalance = address(this).balance;
            IWETH(weth).deposit{value: ethBalance}();
            IERC20(weth).safeTransfer(msg.sender, ethBalance);
            sharesBought = sharesDerivedFromBuyAmount;
            amountSoldFor = _buyAmount + ethBalance;
            emit Sell(sellShares, ethBalance);
        }

        require(sharesBought >= _minSharesToBuy, "failed min shares to buy");
        require(amountSoldFor >= _minAmountFromSell, "failed min amount from sell");

        return (sharesBought, amountSoldFor);
    }

    function syncPrice() external view override returns (uint256) {
        return ICurveFi(triPool).get_virtual_price();
    }

    function harvest() external override onlyOwnerOrController {
        // Harvest CRV
        IMintr(mintr).mint(gauge);
        uint256 crvBalance = IERC20(crv).balanceOf(address(this));
        if (crvBalance > 0) {
            // Sell CRV for more supply token
            IERC20(crv).safeIncreaseAllowance(uniswap, crvBalance);

            address[] memory paths = new address[](3);
            paths[0] = crv;
            paths[1] = weth;
            paths[2] = supplyToken;

            IUniswapV2(uniswap).swapExactTokensForTokens(
                crvBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp.add(1800)
            );

            // Re-invest supply token to obtain more 3CRV
            uint256 obtainedSupplyTokenAmount = IERC20(supplyToken).balanceOf(address(this));
            IERC20(supplyToken).safeIncreaseAllowance(triPool, obtainedSupplyTokenAmount);
            uint256 minMintAmount =
                obtainedSupplyTokenAmount.mul(1e18).mul(10**(18 - supplyTokenDecimals)).div(
                    ICurveFi(triPool).get_virtual_price()
                );
            uint256[3] memory amounts;
            amounts[supplyTokenIndexInPool] = obtainedSupplyTokenAmount;
            ICurveFi(triPool).add_liquidity(amounts, minMintAmount.mul(DENOMINATOR.sub(slippage)).div(DENOMINATOR));

            // Stake 3CRV in Gauge to farm more CRV
            uint256 obtainedTriCrvBalance = IERC20(triCrv).balanceOf(address(this));
            IERC20(triCrv).safeIncreaseAllowance(gauge, obtainedTriCrvBalance);
            IGauge(gauge).deposit(obtainedTriCrvBalance);
        }
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }
}
