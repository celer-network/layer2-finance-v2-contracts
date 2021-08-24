// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/IStrategy.sol";

/**
 * @notice A dummy sample strategy that does nothing with the committed funds.
 * @dev Use ownable to have better control on testnet.
 */
contract StrategyDummy is IStrategy, Ownable {
    using Address for address;
    using SafeERC20 for IERC20;

    address public controller;
    address public asset;

    uint256 public assetAmount;
    uint256 public shares;

    address public funder;
    uint256 public harvestGain;
    bool public alwaysFail;

    uint256 constant MAX_INT = 2**256 - 1;

    constructor(
        address _controller,
        address _asset,
        address _funder,
        uint256 _harvestGain
    ) {
        controller = _controller;
        asset = _asset;
        funder = _funder;
        harvestGain = _harvestGain;
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

    function getAssetAmount() external view override returns (uint256) {
        return assetAmount;
    }

    function getPrice() external view override returns (uint256) {
        if (shares == 0) {
            if (assetAmount == 0) {
                return 1e18;
            }
            return MAX_INT;
        }
        return (assetAmount * 1e18) / shares;
    }

    function aggregateOrders(
        uint256 _buyAmount,
        uint256 _sellShares,
        uint256 _minSharesFromBuy,
        uint256 _minAmountFromSell
    ) external override onlyController returns (uint256, uint256) {
        if (alwaysFail) {
            revert("always fail");
        }

        require(shares >= _sellShares, "not enough shares to sell");
        uint256 sharesFromBuy;
        uint256 amountFromSell;
        if (assetAmount == 0 || shares == 0) {
            shares = _buyAmount;
            assetAmount = _buyAmount;
            sharesFromBuy = shares;
        } else {
            sharesFromBuy = (_buyAmount * shares) / assetAmount;
            amountFromSell = (_sellShares * assetAmount) / shares;
            assetAmount = assetAmount + _buyAmount - amountFromSell;
            shares = shares + sharesFromBuy - _sellShares;
        }
        require(sharesFromBuy >= _minSharesFromBuy, "failed min shares from buy");
        require(amountFromSell >= _minAmountFromSell, "failed min amount from sell");
        if (_buyAmount > amountFromSell) {
            IERC20(asset).safeTransferFrom(controller, address(this), _buyAmount - amountFromSell);
        } else if (_buyAmount < amountFromSell) {
            IERC20(asset).safeTransfer(controller, amountFromSell - _buyAmount);
        }
        if (_buyAmount > 0) {
            emit Buy(_buyAmount, sharesFromBuy);
        }
        if (_sellShares > 0) {
            emit Sell(_sellShares, amountFromSell);
        }

        return (sharesFromBuy, amountFromSell);
    }

    function harvest() external override onlyOwnerOrController {
        IERC20(asset).safeTransferFrom(funder, address(this), harvestGain);
        assetAmount += harvestGain;
    }

    function adjust() external override {}

    function increaseBalance(uint256 _amount) external onlyOwnerOrController {
        IERC20(asset).safeTransferFrom(funder, address(this), _amount);
        assetAmount += _amount;
    }

    function decreaseBalance(uint256 _amount) external onlyOwnerOrController {
        IERC20(asset).safeTransfer(funder, _amount);
        assetAmount -= _amount;
    }

    function setHarvestGain(uint256 _harvestGain) external onlyOwner {
        harvestGain = _harvestGain;
    }

    function setAlwaysFail(bool _alwaysFail) external onlyOwner {
        alwaysFail = _alwaysFail;
    }

    function setFunder(address _funder) external onlyOwner {
        funder = _funder;
    }

    function setController(address _controller) external onlyOwner {
        emit ControllerChanged(controller, _controller);
        controller = _controller;
    }
}
