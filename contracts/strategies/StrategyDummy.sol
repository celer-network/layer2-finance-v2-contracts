// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IStrategy.sol";

/**
 * @notice A dummy sample strategy that does nothing with the committed funds.
 * @dev Use ownable to have better control on testnet.
 */
contract StrategyDummy is IStrategy, Ownable {
    using Address for address;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public controller;
    address public asset;

    uint256 public assetAmount;
    uint256 public shares;

    address public funder;
    uint256 public harvestGain;

    constructor(
        address _controller,
        address _asset,
        address _funder,
        uint256 _harvestGain
    ) {
        controller = _controller;
        funder = _funder;
        asset = _asset;
        harvestGain = _harvestGain;
    }

    modifier onlyController() {
        require(msg.sender == controller, "caller is not controller");
        _;
    }

    function getAssetAddress() external view override returns (address) {
        return asset;
    }

    function aggregateOrder(
        uint256 _buyAmount,
        uint256 _minSharesFromBuy,
        uint256 _sellShares,
        uint256 _minAmountFromSell
    ) external override onlyController returns (uint256, uint256) {
        require(shares >= _sellShares, "not enough shares to sell");
        uint256 sharesFromBuy;
        uint256 amountFromSell;
        if (assetAmount == 0 || shares == 0) {
            shares = _buyAmount;
            assetAmount = _buyAmount;
            sharesFromBuy = shares;
        } else {
            sharesFromBuy = _buyAmount.mul(shares).div(assetAmount);
            amountFromSell = _sellShares.mul(assetAmount).div(shares);
            assetAmount = assetAmount.add(_buyAmount).sub(amountFromSell);
            shares = shares.add(sharesFromBuy).sub(_sellShares);
        }
        require(sharesFromBuy >= _minSharesFromBuy, "failed min shares from buy");
        require(amountFromSell >= _minAmountFromSell, "failed min amount from sell");
        if (_buyAmount > amountFromSell) {
            IERC20(asset).safeTransferFrom(controller, address(this), _buyAmount.sub(amountFromSell));
        } else if (_buyAmount < amountFromSell) {
            IERC20(asset).safeTransfer(controller, amountFromSell.sub(_buyAmount));
        }
        return (sharesFromBuy, amountFromSell);
    }

    function syncPrice() external view override returns (uint256) {
        return assetAmount.mul(1e18).div(shares);
    }

    function harvest() external override onlyOwner {
        IERC20(asset).safeTransferFrom(funder, address(this), harvestGain);
        assetAmount.add(harvestGain);
    }

    function setHarvestGain(uint256 _harvestGain) external onlyOwner {
        harvestGain = _harvestGain;
    }

    function increaseBalance(uint256 _amount) external onlyOwner {
        IERC20(asset).safeTransferFrom(funder, address(this), _amount);
        assetAmount.add(_amount);
    }

    function decreaseBalance(uint256 _amount) external onlyOwner {
        IERC20(asset).safeTransfer(funder, _amount);
        assetAmount.sub(_amount);
    }

    function setFunder(address _funder) external onlyOwner {
        funder = _funder;
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }
}
