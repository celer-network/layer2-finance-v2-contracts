// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../AbstractStrategy.sol";
import "../interfaces/compound/ICErc20.sol";
import "../interfaces/compound/IComptroller.sol";
import "../interfaces/uniswap/IUniswapV2.sol";

contract StrategyCompoundErc20LendingPool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of Compound interest-bearing token (e.g. cDAI, cUSDT)
    address public cErc20;

    // The address of Cream interest-bearing token (e.g. crDAI, crUSDT)
    address public crErc20;

    // The address is used for claim COMP token
    address public comptroller;

    // The address is used for claim CREAM token
    address public creamtroller;

    // The address of COMP token
    address public comp;

    // The address of CREAM token
    address public cream;

    address public uniswap;
    // The address of WETH token
    address public weth;

    constructor(
        address _supplyToken,
        address _cErc20,
        address _crErc20,
        address _comptroller,
        address _creamtroller,
        address _comp,
        address _cream,
        address _uniswap,
        address _weth,
        address _controller
    ) AbstractStrategy(_controller, _supplyToken) {
        cErc20 = _cErc20;
        crErc20 = _crErc20;
        comptroller = _comptroller;
        creamtroller = _creamtroller;
        comp = _comp;
        cream = _cream;
        uniswap = _uniswap;
        weth = _weth;
    }

    /**
     * @dev Require that the caller must be an EOA account to avoid flash loans.
     */
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Not EOA");
        _;
    }

    function getAssetAmount() internal override returns (uint256) {
        return ICErc20(cErc20).balanceOfUnderlying(address(this)) + ICErc20(crErc20).balanceOfUnderlying(address(this));
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
         uint256 originalAssetAmount = getAssetAmount();

        // Pull supplying token(e.g. DAI, USDT) from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);
        uint256 mintResult;

        if (ICErc20(cErc20).supplyRatePerBlock() > ICErc20(crErc20).supplyRatePerBlock()) {
            // Deposit supplying token to Compound Erc20 Lending Pool and mint cErc20.
            IERC20(supplyToken).safeIncreaseAllowance(cErc20, _buyAmount);
            mintResult = ICErc20(cErc20).mint(_buyAmount);
        } else {
            // Deposit supplying token to Cream Erc20 Lending Pool and mint crErc20.
            IERC20(supplyToken).safeIncreaseAllowance(crErc20, _buyAmount);
            mintResult = ICErc20(crErc20).mint(_buyAmount);
        }
        uint256 newAssetAmount = getAssetAmount();
        
        return newAssetAmount - originalAssetAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        uint256 balanceBeforeSell = IERC20(supplyToken).balanceOf(address(this));

        ICErc20 lowRateProtocol = ICErc20(cErc20);
        ICErc20 highRateProtocol = ICErc20(crErc20);
        if (lowRateProtocol.supplyRatePerBlock() > highRateProtocol.supplyRatePerBlock()) {
            lowRateProtocol = ICErc20(crErc20);
            highRateProtocol = ICErc20(cErc20);
        }

        uint256 redeemResult;
        uint256 lowRateBalance = lowRateProtocol.balanceOfUnderlying(address(this));
        if (_sellAmount < lowRateBalance) {
            lowRateBalance = _sellAmount;
        } else {
            redeemResult = highRateProtocol.redeemUnderlying(_sellAmount - lowRateBalance);
            require(redeemResult == 0, "Couldn't redeem cToken");
        }

        redeemResult = lowRateProtocol.redeemUnderlying(lowRateBalance);
        require(redeemResult == 0, "Couldn't redeem cToken");

        // Transfer supplying token(e.g. DAI, USDT) to Controller
        uint256 balanceAfterSell = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, balanceAfterSell);

        return balanceAfterSell - balanceBeforeSell;
    }

    function harvest() external override onlyEOA {
        // Claim COMP token.
        IComptroller(comptroller).claimComp(address(this));
        uint256 compBalance = IERC20(comp).balanceOf(address(this));
        if (compBalance > 0) {
            // Sell COMP token for obtain more supplying token(e.g. DAI, USDT)
            IERC20(comp).safeIncreaseAllowance(uniswap, compBalance);

            address[] memory paths = new address[](3);
            paths[0] = comp;
            paths[1] = weth;
            paths[2] = supplyToken;

            IUniswapV2(uniswap).swapExactTokensForTokens(
                compBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp + 1800
            );
        }

        // Claim CREAM token.
        IComptroller(creamtroller).claimComp(address(this));
        uint256 creamBalance = IERC20(cream).balanceOf(address(this));
        if (creamBalance > 0) {
            // Sell CREAM token for obtain more supplying token(e.g. DAI, USDT)
            IERC20(cream).safeIncreaseAllowance(uniswap, creamBalance);

            address[] memory paths = new address[](3);
            paths[0] = cream;
            paths[1] = weth;
            paths[2] = supplyToken;

            IUniswapV2(uniswap).swapExactTokensForTokens(
                creamBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp + 1800
            );
        }

        adjust();
    }

    function adjust() public {
        require(msg.sender == controller, "Not controller");

        ICErc20 lowRateProtocol = ICErc20(cErc20);
        ICErc20 highRateProtocol = ICErc20(crErc20);
        if (lowRateProtocol.supplyRatePerBlock() > highRateProtocol.supplyRatePerBlock()) {
            lowRateProtocol = ICErc20(crErc20);
            highRateProtocol = ICErc20(cErc20);
        }

        uint256 lowRateBalance = lowRateProtocol.balanceOfUnderlying(address(this));

        uint256 redeemResult = lowRateProtocol.redeemUnderlying(lowRateBalance);
        require(redeemResult == 0, "Couldn't redeem cToken/crToken");

        uint256 supplyTokenBalance = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeIncreaseAllowance(address(highRateProtocol), supplyTokenBalance);
        uint256 mintResult = highRateProtocol.mint(supplyTokenBalance);
        require(mintResult == 0, "Couldn't mint cToken/crToken");
    }
}