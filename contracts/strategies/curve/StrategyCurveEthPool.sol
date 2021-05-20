// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IStrategy.sol";

contract StrategyCurveEthPool is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public controller;

    // contract addresses
    address public ethPool; // Curve ETH/? swap pool
    address public gauge; // Curve gauge
    address public mintr; // Curve minter
    address public uniswap; // UniswapV2

    // supply token (WETH) params
    uint8 public ethIndexInPool = 0; // ETH - 0, Other - 1

    // token addresses
    address public lpToken; // LP token
    address public crv; // CRV token
    address public weth; // WETH token

    // slippage tolerance settings
    uint256 public constant DENOMINATOR = 10000;
    uint256 public slippage = 500;

    uint256 MAX_INT = 2**256 - 1;

    constructor(
        address _controller,
        uint8 _ethIndexInPool,
        address _ethPool,
        address _lpToken,
        address _gauge,
        address _mintr,
        address _crv,
        address _weth,
        address _uniswap
    ) {
        controller = _controller;
        ethIndexInPool = _ethIndexInPool;
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

        uint256 price = ICurveFi(ethPool).get_virtual_price();
        uint256 amountDerivedFromSellShares = _sellShares.div(1e18).mul(price); // amount to be obtained from selling LP Token
        uint256 sharesDerivedFromBuyAmount = _buyAmount.mul(1e18).div(price); // LP Token to get obtained from buying with ETH

        uint256 sharesBought; // bought shares from share sellers and/or curvefi
        uint256 amountSoldFor; // ETH for which the sellers' shares are sold

        if (sharesDerivedFromBuyAmount > _sellShares) {
            // LP Token amount to sell in this batch can't cover the share amount of LP tokens people want to buy
            // therefore we need buy more LP Tokens to cover the demand for more LP Tokens.
            uint256 buyAmount = _buyAmount - amountDerivedFromSellShares;
            IERC20(weth).safeTransferFrom(msg.sender, address(this), buyAmount);
            IWETH(weth).withdraw(buyAmount);
            uint256[2] memory amounts;
            amounts[ethIndexInPool] = buyAmount;
            ICurveFi(ethPool).add_liquidity{value: buyAmount}(
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
            IERC20(weth).safeTransferFrom(msg.sender, address(this), sellShares);
            ICurveFi(ethPool).remove_liquidity_one_coin(
                sellShares,
                ethIndexInPool,
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
        return ICurveFi(ethPool).get_virtual_price();
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
                block.timestamp.add(1800)
            );

            // Re-invest supply token to obtain more lpToken
            uint256 obtainedEthAmount = address(this).balance;
            uint256 minMintAmount =
                obtainedEthAmount
                    .mul(1e18)
                    .div(ICurveFi(ethPool).get_virtual_price())
                    .mul(DENOMINATOR.sub(slippage))
                    .div(DENOMINATOR);
            uint256[2] memory amounts;
            amounts[ethIndexInPool] = obtainedEthAmount;
            ICurveFi(ethPool).add_liquidity{value: obtainedEthAmount}(amounts, minMintAmount);

            // Stake lpToken in Gauge to farm more CRV
            uint256 obtainedTriCrvBalance = IERC20(lpToken).balanceOf(address(this));
            IERC20(lpToken).safeIncreaseAllowance(gauge, obtainedTriCrvBalance);
            IGauge(gauge).deposit(obtainedTriCrvBalance);
        }
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }
}
