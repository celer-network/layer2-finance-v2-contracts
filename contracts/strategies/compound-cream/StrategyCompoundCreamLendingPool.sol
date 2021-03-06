// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../base/AbstractStrategy.sol";
import "../compound/interfaces/ICErc20.sol";
import "../compound/interfaces/IComptroller.sol";
import "../uniswap-v2/interfaces/IUniswapV2Router02.sol";

contract StrategyCompoundCreamLendingPool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of Compound interest-bearing token (e.g. cDAI, cUSDT)
    address public immutable cErc20;
    // The address of Cream interest-bearing token (e.g. crDAI, crUSDT)
    address public immutable crErc20;
    // The address is used for claim COMP token
    address public immutable comptroller;
    // The address is used for claim CREAM token
    address public immutable creamtroller;
    // The address of COMP token
    address public immutable comp;
    // The address of CREAM token
    address public immutable cream;
    // The address of the Uniswap V2 router
    address public immutable uniswap;
    // The address of WETH token
    address public immutable weth;

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

    function getAssetAmount() public view override returns (uint256) {
        uint256 cAmount = (ICErc20(cErc20).exchangeRateStored() * ICErc20(cErc20).balanceOf(address(this))) / 1e18;
        uint256 crAmount = (ICErc20(crErc20).exchangeRateStored() * ICErc20(crErc20).balanceOf(address(this))) / 1e18;
        return cAmount + crAmount;
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
        if (_sellAmount <= lowRateBalance) {
            lowRateBalance = _sellAmount;
        } else {
            redeemResult = highRateProtocol.redeemUnderlying(_sellAmount - lowRateBalance);
            require(redeemResult == 0, "Couldn't redeem cToken/crToken");
        }

        if (lowRateBalance > 0) {
            uint256 lowRateTokenBalance = lowRateProtocol.balanceOf(address(this));
            if (
                lowRateTokenBalance > 0 /* to avoid redeemTokens zero error */
            ) {
                redeemResult = lowRateProtocol.redeemUnderlying(lowRateBalance);
                require(redeemResult == 0, "Couldn't redeem cToken/crToken");
            }
        }

        // Transfer supplying token(e.g. DAI, USDT) to Controller
        uint256 balanceAfterSell = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, balanceAfterSell);

        return balanceAfterSell - balanceBeforeSell;
    }

    function harvest() external override onlyEOA {
        // Claim COMP token.
        address[] memory holders = new address[](1);
        holders[0] = address(this);
        ICErc20[] memory cTokens = new ICErc20[](1);
        cTokens[0] = ICErc20(cErc20);
        IComptroller(comptroller).claimComp(holders, cTokens, false, true);
        uint256 compBalance = IERC20(comp).balanceOf(address(this));
        if (compBalance > 0) {
            // Sell COMP token for obtain more supplying token(e.g. DAI, USDT)
            IERC20(comp).safeIncreaseAllowance(uniswap, compBalance);

            address[] memory paths = new address[](3);
            paths[0] = comp;
            paths[1] = weth;
            paths[2] = supplyToken;

            // TODO: Check price
            IUniswapV2Router02(uniswap).swapExactTokensForTokens(
                compBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp + 1800
            );
        }

        // Claim CREAM token.
        cTokens[0] = ICErc20(crErc20);
        IComptroller(creamtroller).claimComp(holders, cTokens, false, true);
        uint256 creamBalance = IERC20(cream).balanceOf(address(this));
        if (creamBalance > 0) {
            // Sell CREAM token for obtain more supplying token(e.g. DAI, USDT)
            IERC20(cream).safeIncreaseAllowance(uniswap, creamBalance);

            address[] memory paths = new address[](3);
            paths[0] = cream;
            paths[1] = weth;
            paths[2] = supplyToken;

            IUniswapV2Router02(uniswap).swapExactTokensForTokens(
                creamBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp + 1800
            );
        }

        _adjust();
    }

    function adjust() external override {
        _adjust();
    }

    function _adjust() private {
        ICErc20 lowRateProtocol = ICErc20(cErc20);
        ICErc20 highRateProtocol = ICErc20(crErc20);
        if (lowRateProtocol.supplyRatePerBlock() > highRateProtocol.supplyRatePerBlock()) {
            lowRateProtocol = ICErc20(crErc20);
            highRateProtocol = ICErc20(cErc20);
        }

        uint256 lowRateTokenBalance = lowRateProtocol.balanceOf(address(this));
        if (lowRateTokenBalance > 0) {
            uint256 redeemResult = lowRateProtocol.redeem(lowRateTokenBalance);
            require(redeemResult == 0, "Couldn't redeem cToken/crToken");
        }

        uint256 supplyTokenBalance = IERC20(supplyToken).balanceOf(address(this));
        if (supplyTokenBalance > 0) {
            IERC20(supplyToken).safeIncreaseAllowance(address(highRateProtocol), supplyTokenBalance);
            uint256 mintResult = highRateProtocol.mint(supplyTokenBalance);
            require(mintResult == 0, "Couldn't mint cToken/crToken");
        }
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](4);
        protected[0] = cErc20;
        protected[1] = crErc20;
        protected[2] = comp;
        protected[3] = cream;
        return protected;
    }

    receive() external payable {}

    fallback() external payable {}
}
