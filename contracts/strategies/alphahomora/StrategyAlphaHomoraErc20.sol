// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../base/AbstractStrategy.sol";
import "./interfaces/ISafeBox.sol";
import "./interfaces/IYearnToken.sol";

/**
 * Deposits ERC20 token into Alpha Homora v2 SafeBox Interest Bearing ERC20 token contract
 */
contract StrategyAlphaHomoraErc20 is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of Alpha Homora v2 interest-bearing token, eg. ibUSDTv2
    address public immutable ibToken;

    // _supplyToken must be the same as _ibToken.uToken
    constructor(
        address _ibToken,
        address _supplyToken,
        address _controller
    ) AbstractStrategy(_controller, _supplyToken) {
        ibToken = _ibToken;
    }

    function getAssetAmount() public view override returns (uint256) {
        // ib token equals cyToken
        uint256 tokenBal = ISafeBox(ibToken).balanceOf(address(this));
        return (tokenBal * IYearnToken(ISafeBox(ibToken).cToken()).exchangeRateStored()) / 1e18;
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        uint256 originalAssetAmount = getAssetAmount();

        // Pull supplying token(e.g. DAI, USDT) from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // Deposit supplying token to ibToken
        IERC20(supplyToken).safeIncreaseAllowance(ibToken, _buyAmount);
        ISafeBox(ibToken).deposit(_buyAmount);

        uint256 newAssetAmount = getAssetAmount();
        return newAssetAmount - originalAssetAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        uint256 balanceBeforeSell = IERC20(supplyToken).balanceOf(address(this));
        // Withdraw from homora v2
        // as withdraw expects ibToken, need to convert by divide price
        uint256 yrate = IYearnToken(ISafeBox(ibToken).cToken()).exchangeRateCurrent();
        ISafeBox(ibToken).withdraw((_sellAmount * 1e18) / yrate);
        // Transfer supplying token(e.g. DAI, USDT) to Controller
        uint256 balanceAfterSell = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, balanceAfterSell);
        return balanceAfterSell - balanceBeforeSell;
    }

    // SafeBox requires bytes32[] proof to claim. see alpha-homora-v2-contract/blob/master/contracts/SafeBox.sol#L67
    // for more details
    function harvest(uint256 totalAmount, bytes32[] memory proof) external {
        uint256 balanceBeforeClaim = IERC20(supplyToken).balanceOf(address(this));

        // Claim from homora v2. after verify merkle root, we get totalAmount - claimed[msg.sender]
        // then claimed[msg.sender] is set to totalAmount
        ISafeBox(ibToken).claim(totalAmount, proof);

        uint256 balanceAfterClaim = IERC20(supplyToken).balanceOf(address(this));

        // deposit new usdt into ibToken
        uint256 _buyAmount = balanceAfterClaim - balanceBeforeClaim;
        IERC20(supplyToken).safeIncreaseAllowance(ibToken, _buyAmount);
        ISafeBox(ibToken).deposit(_buyAmount);
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](1);
        protected[0] = ibToken;
        return protected;
    }
}
