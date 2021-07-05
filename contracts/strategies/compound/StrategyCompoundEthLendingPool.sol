// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/compound/ICEth.sol";
import "../interfaces/compound/IComptroller.sol";
import "../interfaces/uniswap/IUniswapV2.sol";
import "../../interfaces/IWETH.sol";

/**
 * Deposits ETH into Compound Lending Pool and issues stCompoundLendingETH in L2. Holds cToken (Compound interest-bearing tokens).
 */
contract StrategyCompoundEthLendingPool is IStrategy, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // The address of Compound interest-bearing ETH
    address payable public cEth;

    // The address is used for claim COMP token
    address public comptroller;
    // The address of COMP token
    address public comp;

    address public uniswap;
    // The address of WETH token
    address public weth;

    address public controller;

    uint256 internal constant MAX_INT = 2**256 - 1;
    uint256 public assetAmount;
    uint256 public shares;

    constructor(
        address payable _cEth,
        address _comptroller,
        address _comp,
        address _uniswap,
        address _weth,
        address _controller
    ) {
        cEth = _cEth;
        comptroller = _comptroller;
        comp = _comp;
        uniswap = _uniswap;
        weth = _weth;
        controller = _controller;
    }

    /**
     * @dev Require that the caller must be an EOA account to avoid flash loans.
     */
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Not EOA");
        _;
    }

    /**
     * @dev Return WETH address. StrategyCompoundETH contract receive WETH from controller.
     */
    function getAssetAddress() external view override returns (address) {
        return weth;
    }

    function aggregateOrders(
        uint256 _buyAmount,
        uint256 _sellShares,
        uint256 _minSharesFromBuy,
        uint256 _minAmountFromSell
    ) external override returns (uint256, uint256) {
        require(msg.sender == controller, "Not controller");
        require(shares >= _sellShares, "not enough shares to sell");

        // 1. Deposit or withdrawal
        uint256 sharesFromBuy;
        uint256 amountFromSell;
        assetAmount = ICEth(cEth).balanceOfUnderlying(address(this));
        if (assetAmount == 0 || shares == 0) {
            shares = _buyAmount;
            assetAmount = _buyAmount;
            sharesFromBuy = _buyAmount;
        } else {
            sharesFromBuy = _buyAmount.mul(shares).div(assetAmount);
            amountFromSell = _sellShares.mul(assetAmount).div(shares);
            assetAmount = assetAmount.add(_buyAmount).sub(amountFromSell);
            shares = shares.add(sharesFromBuy).sub(_sellShares);
        }
        require(sharesFromBuy >= _minSharesFromBuy, "failed min shares from buy");
        require(amountFromSell >= _minAmountFromSell, "failed min amount from sell");
        if (_buyAmount > amountFromSell) {
            _buy(_buyAmount - amountFromSell);
        } else if (_buyAmount < amountFromSell) {
            _sell(amountFromSell - _buyAmount);
        }

        if (_buyAmount > 0) {
            emit Buy(_buyAmount, sharesFromBuy);
        }
        if (_sellShares > 0) {
            emit Sell(_sellShares, amountFromSell);
        }

        return (sharesFromBuy, amountFromSell);
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

    function harvest() external override onlyEOA {
        // Claim COMP token.
        IComptroller(comptroller).claimComp(address(this));
        uint256 compBalance = IERC20(comp).balanceOf(address(this));
        if (compBalance > 0) {
            // Sell COMP token for obtain more ETH
            IERC20(comp).safeIncreaseAllowance(uniswap, compBalance);

            address[] memory paths = new address[](2);
            paths[0] = comp;
            paths[1] = weth;

            IUniswapV2(uniswap).swapExactTokensForETH(
                compBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp.add(1800)
            );

            // Deposit ETH to Compound ETH Lending Pool and mint cETH.
            uint256 obtainedEthAmount = address(this).balance;
            ICEth(cEth).mint{value: obtainedEthAmount}();
        }

        // sync the asset balance
        assetAmount = ICEth(cEth).balanceOfUnderlying(address(this));
    }

    function _buy(uint256 _buyAmount) private {
        // Pull WETH from Controller
        IERC20(weth).safeTransferFrom(msg.sender, address(this), _buyAmount);
        // Convert WETH into ETH
        IWETH(weth).withdraw(_buyAmount);

        // Deposit ETH to Compound ETH Lending Pool and mint cETH.
        ICEth(cEth).mint{value: _buyAmount}();
    }

    function _sell(uint256 _sellAmount) private {
        // Withdraw ETH from Compound ETH Lending Pool based on an amount of ETH.
        uint256 redeemResult = ICEth(cEth).redeemUnderlying(_sellAmount);
        require(redeemResult == 0, "Couldn't redeem cToken");

        // Convert ETH into WETH
        uint256 ethBalance = address(this).balance;
        IWETH(weth).deposit{value: ethBalance}();
        // Transfer WETH to Controller
        IERC20(weth).safeTransfer(msg.sender, ethBalance);
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }

    // This is needed to receive ETH when calling `ICEth.redeemUnderlying` and `IWETH.withdraw`
    receive() external payable {}

    fallback() external payable {}
}
