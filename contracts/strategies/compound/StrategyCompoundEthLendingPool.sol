// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../interfaces/IWETH.sol";
import "../base/AbstractStrategy.sol";
import "../uniswap-v2/interfaces/IUniswapV2Router02.sol";
import "./interfaces/ICEth.sol";
import "./interfaces/IComptroller.sol";

/**
 * Deposits ETH into Compound Lending Pool and issues stCompoundLendingETH in L2. Holds cToken (Compound interest-bearing tokens).
 */
contract StrategyCompoundEthLendingPool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of Compound interest-bearing ETH
    address payable public cEth;

    // The address is used for claim COMP token
    address public comptroller;
    // The address of COMP token
    address public comp;

    address public uniswap;

    constructor(
        address payable _cEth,
        address _comptroller,
        address _comp,
        address _uniswap,
        address _weth, // weth as supply token
        address _controller
    ) AbstractStrategy(_controller, _weth) {
        cEth = _cEth;
        comptroller = _comptroller;
        comp = _comp;
        uniswap = _uniswap;
    }

    /**
     * @dev Require that the caller must be an EOA account to avoid flash loans.
     */
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Not EOA");
        _;
    }

    function getAssetAmount() internal override returns (uint256) {
        return ICEth(cEth).balanceOfUnderlying(address(this));
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        uint256 originalAssetAmount = getAssetAmount();

        // Pull WETH from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);
        // Convert WETH into ETH
        IWETH(supplyToken).withdraw(_buyAmount);
        // Deposit ETH to Compound ETH Lending Pool and mint cETH.
        ICEth(cEth).mint{value: _buyAmount}();

        uint256 newAssetAmount = getAssetAmount();

        return newAssetAmount - originalAssetAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        uint256 balanceBeforeSell = address(this).balance;

        // Withdraw ETH from Compound ETH Lending Pool based on an amount of ETH.
        uint256 redeemResult = ICEth(cEth).redeemUnderlying(_sellAmount);
        require(redeemResult == 0, "Couldn't redeem cToken");
        // Convert ETH into WETH
        uint256 balanceAfterSell = address(this).balance;
        IWETH(supplyToken).deposit{value: balanceAfterSell}();
        // Transfer WETH to Controller
        IERC20(supplyToken).safeTransfer(msg.sender, balanceAfterSell);

        return balanceAfterSell - balanceBeforeSell;
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
            paths[1] = supplyToken;

            IUniswapV2Router02(uniswap).swapExactTokensForETH(
                compBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp + 1800
            );

            // Deposit ETH to Compound ETH Lending Pool and mint cETH.
            uint256 obtainedEthAmount = address(this).balance;
            ICEth(cEth).mint{value: obtainedEthAmount}();
        }
    }

    // This is needed to receive ETH when calling `ICEth.redeemUnderlying` and `IWETH.withdraw`
    receive() external payable {}

    fallback() external payable {}
}
