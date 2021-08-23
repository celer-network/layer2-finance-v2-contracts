// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../interfaces/IWETH.sol";
import "../base/AbstractStrategy.sol";
import "./interfaces/ISafeBoxEth.sol";
import "./interfaces/IYearnToken.sol";

/**
 * Deposits WETH into Alpha Homora v2 SafeBox Interest Bearing ERC20 token contract
 */
contract StrategyAlphaHomoraEth is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of Alpha Homora v2 interest-bearing token, eg. ibUSDTv2
    address payable public ibToken;

    constructor(
        address payable _ibToken,
        address _supplyToken,
        address _controller
    ) AbstractStrategy(_controller, _supplyToken) {
        ibToken = _ibToken;
    }

    /**
     * @dev Require that the caller must be an EOA account to avoid flash loans.
     */
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Not EOA");
        _;
    }

    function getAssetAmount() internal override returns (uint256) {
        // ib token equals cyToken
        uint256 tokenBal = ISafeBoxEth(ibToken).balanceOf(address(this));
        return (tokenBal * IYearnToken(ISafeBoxEth(ibToken).cToken()).exchangeRateCurrent()) / 1e18;
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        uint256 originalAssetAmount = getAssetAmount();

        // Pull supplying token(e.g. DAI, USDT) from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // convert to actual ETH as deposit will do weth convert internally
        IWETH(supplyToken).withdraw(_buyAmount);
        // Deposit supplying token to ibToken
        ISafeBoxEth(ibToken).deposit{value: _buyAmount}();

        uint256 newAssetAmount = getAssetAmount();
        return newAssetAmount - originalAssetAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        uint256 balanceBeforeSell = address(this).balance;

        // Withdraw from homora v2
        uint256 yrate = IYearnToken(ISafeBoxEth(ibToken).cToken()).exchangeRateCurrent();
        ISafeBoxEth(ibToken).withdraw((_sellAmount * 1e18) / yrate);

        // Deposit to WETH and transfer to Controller
        uint256 balanceAfterSell = address(this).balance;
        IWETH(supplyToken).deposit{value: balanceAfterSell}();
        IERC20(supplyToken).safeTransfer(msg.sender, balanceAfterSell);

        return balanceAfterSell - balanceBeforeSell;
    }

    // no-op just to satisfy IStrategy
    function harvest() external override onlyEOA {}

    // SafeBox requires bytes32[] proof to claim. see alpha-homora-v2-contract/blob/master/contracts/SafeBox.sol#L67
    // for more details
    function harvest(uint256 totalAmount, bytes32[] memory proof) external onlyEOA {
        uint256 balanceBeforeClaim = address(this).balance;

        // Claim from homora v2. after verify merkle root, we get totalAmount - claimed[msg.sender]
        // then claimed[msg.sender] is set to totalAmount
        ISafeBoxEth(ibToken).claim(totalAmount, proof);

        uint256 balanceAfterClaim = address(this).balance;

        // deposit new eth into ibToken
        uint256 _buyAmount = balanceAfterClaim - balanceBeforeClaim;
        ISafeBoxEth(ibToken).deposit{value: _buyAmount}();
    }

    // needed for weth.withdraw
    receive() external payable {}

    fallback() external payable {}
}
