// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../AbstractStrategy.sol";
import "../interfaces/alphahomora/ISafeBox.sol";

/**
 * Deposits ERC20 token into Alpha Homora v2 SafeBox Interest Bearing ERC20 token contract
 */
contract StrategyAlphaHomoraErc20 is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of Alpha Homora v2 interest-bearing token, eg. ibUSDTv2
    address public ibToken;
    // _supplyToken must be the same as _ibToken.uToken
    constructor(
        address _ibToken,
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
        return ISafeBox(ibToken).balanceOf(address(this));
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
        ISafeBox(ibToken).withdraw(_sellAmount);
        // Transfer supplying token(e.g. DAI, USDT) to Controller
        uint256 balanceAfterSell = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, balanceAfterSell);

        return balanceAfterSell - balanceBeforeSell;
    }    

    // no-op just to satisfy IStrategy
    function harvest() external override onlyEOA {
    }

    // SafeBox requires bytes32[] proof to claim. see alpha-homora-v2-contract/blob/master/contracts/SafeBox.sol#L67
    // for more details
    function harvest(uint totalAmount, bytes32[] memory proof) external onlyEOA {
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
}
