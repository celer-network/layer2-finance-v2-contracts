// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../base/AbstractStrategy.sol";
import "../uniswap-v2/interfaces/IUniswapV2Router02.sol";
import "./interfaces/IDODOMine.sol";
import "./interfaces/IDODOV1.sol";
import "./interfaces/IDODOV2Proxy01.sol";

/**
 * Deposits ERC20 token into DODO V1 Pool and stakes LP tokens to mine DODO.
 */
contract StrategyDODOV1 is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of the DODO token
    address public dodo;
    // The address of the USDT token
    address public usdt;
    // The address of the DODO V1 pair / pool
    address public dodoPairAddress;
    // The address of the DODO proxy
    address public dodoProxy;
    // The address of the DODO mining pool
    address public dodoMine;
    // The address of the DODO Approve contract
    address public dodoApprove;
    // The address of the DODO V1 DODO-USDT pair
    address public dodoV1_DODO_USDT_Pair;
    // The address of the Uniswap V2 router
    address public uniV2Router;

    uint256 public slippage = 2000;
    uint256 public constant SLIPPAGE_DENOMINATOR = 10000;

    uint256 public harvestThreshold = 50e18;
    bool supplyBase;
    address lpToken;

    constructor(
        address _supplyToken,
        address _dodo,
        address _usdt,
        address _dodoPair,
        address _dodoProxy,
        address _dodoMine,
        address _dodoApprove,
        address _dodoV1_DODO_USDT_Pair,
        address _uniV2Router,
        address _controller
    ) AbstractStrategy(_controller, _supplyToken) {
        dodo = _dodo;
        usdt = _usdt;
        dodoPairAddress = _dodoPair;
        dodoProxy = _dodoProxy;
        dodoMine = _dodoMine;
        dodoApprove = _dodoApprove;
        dodoV1_DODO_USDT_Pair = _dodoV1_DODO_USDT_Pair;
        uniV2Router = _uniV2Router;

        IDODOV1 dodoPair = IDODOV1(dodoPairAddress);
        if (supplyToken == IDODOV1(dodoPair)._BASE_TOKEN_()) {
            supplyBase = true;
            lpToken = dodoPair._BASE_CAPITAL_TOKEN_();
        } else {
            supplyBase = false;
            lpToken = dodoPair._QUOTE_CAPITAL_TOKEN_();
        }
    }

    function getAssetAmount() internal view override returns (uint256) {
        if (supplyToken == IDODOV1(dodoPairAddress)._BASE_TOKEN_()) {
            return getBaseAmount();
        }
        return getQuoteAmount();
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        uint256 originalAssetAmount = getAssetAmount();

        // Pull supply token from Controller.
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // Deposit supply token to the DODO pool.
        IDODOV1 dodoPair = IDODOV1(dodoPairAddress);
        IERC20(supplyToken).safeIncreaseAllowance(dodoPairAddress, _buyAmount);
        // TODO: Check price
        if (supplyBase) {
            dodoPair.depositBase(_buyAmount);
        } else {
            dodoPair.depositQuote(_buyAmount);
        }

        // Stake LP to earn DODO rewards
        uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));
        if (lpBalance > 0) {
            IERC20(lpToken).safeIncreaseAllowance(dodoMine, lpBalance);
            IDODOMine(dodoMine).deposit(lpToken, lpBalance);
        }

        uint256 newAssetAmount = getAssetAmount();
        return newAssetAmount - originalAssetAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        uint256 balanceBeforeSell = IERC20(supplyToken).balanceOf(address(this));

        // Unstake LP
        IDODOV1 dodoPair = IDODOV1(dodoPairAddress);
        (uint256 stakedLpAmount, ) = IDODOMine(dodoMine).userInfo(IDODOMine(dodoMine).getPid(lpToken), address(this));
        IDODOMine(dodoMine).withdraw(lpToken, stakedLpAmount);

        // Withdraw supply token from the DODO pool.
        IDODOV1 dodoPool = IDODOV1(dodoPair);
        if (supplyBase) {
            dodoPool.withdrawBase(_sellAmount);
        } else {
            dodoPool.withdrawQuote(_sellAmount);
        }

        // Transfer supply token to Controller
        uint256 balanceAfterSell = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, balanceAfterSell);

        // Re-stake LP
        uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));
        if (lpBalance > 0) {
            IERC20(lpToken).safeIncreaseAllowance(dodoMine, lpBalance);
            IDODOMine(dodoMine).deposit(lpToken, lpBalance);
        }

        return balanceAfterSell - balanceBeforeSell;
    }

    function harvest() external override {
        // Sell DODO rewards to USDT on DODO's DODO-USDT pool, then sell the USDT on Uniswap V2 if necessary.
        IDODOMine(dodoMine).claim(lpToken);
        uint256 dodoBalance = IERC20(dodo).balanceOf(address(this));
        if (dodoBalance < harvestThreshold) {
            return;
        }

        IERC20(dodo).safeIncreaseAllowance(dodoApprove, dodoBalance);
        address[] memory dodoV1Pairs = new address[](1);
        dodoV1Pairs[0] = dodoV1_DODO_USDT_Pair;
        IDODOV2Proxy01(dodoProxy).dodoSwapV1(dodo, usdt, dodoBalance, 1, dodoV1Pairs, 0, false, block.timestamp + 1800);

        uint256 usdtBalance = IERC20(usdt).balanceOf(address(this));
        if (supplyToken != usdt) {
            address[] memory paths = new address[](2);
            paths[0] = usdt;
            paths[1] = supplyToken;
            IERC20(usdt).safeIncreaseAllowance(uniV2Router, usdtBalance);
            IUniswapV2Router02(uniV2Router).swapExactTokensForTokens(
                usdtBalance,
                0,
                paths,
                address(this),
                block.timestamp + 1800
            );
        }

        // Deposit supply token to the DODO pool.
        uint256 supplyTokenBalance = IERC20(supplyToken).balanceOf(address(this));
        IDODOV1 dodoPair = IDODOV1(dodoPairAddress);
        IERC20(supplyToken).safeIncreaseAllowance(dodoPairAddress, supplyTokenBalance);
        // TODO: Check price
        if (supplyBase) {
            dodoPair.depositBase(supplyTokenBalance);
        } else {
            dodoPair.depositQuote(supplyTokenBalance);
        }

        // Stake LP to earn DODO rewards
        uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));
        if (lpBalance > 0) {
            IERC20(lpToken).safeIncreaseAllowance(dodoMine, lpBalance);
            IDODOMine(dodoMine).deposit(lpToken, lpBalance);
        }
    }

    function setSlippage(uint256 _slippage) external onlyOwner {
        slippage = _slippage;
    }

    function setHarvestThreshold(uint256 _harvestThreshold) external onlyOwner {
        harvestThreshold = _harvestThreshold;
    }

    function getBaseAmount() public view returns (uint256) {
        IDODOV1 dodoPair = IDODOV1(dodoPairAddress);
        uint256 totalBaseCapital = dodoPair.getTotalBaseCapital();
        if (totalBaseCapital == 0) {
            return 0;
        }
        (uint256 baseTarget, ) = dodoPair.getExpectedTarget();
        (uint256 stakedLpAmount, ) = IDODOMine(dodoMine).userInfo(IDODOMine(dodoMine).getPid(lpToken), address(this));
        return ((stakedLpAmount + dodoPair.getBaseCapitalBalanceOf(address(this))) * baseTarget) / totalBaseCapital;
    }

    function getQuoteAmount() public view returns (uint256) {
        IDODOV1 dodoPair = IDODOV1(dodoPairAddress);
        uint256 totalQuoteCapital = dodoPair.getTotalQuoteCapital();
        if (totalQuoteCapital == 0) {
            return 0;
        }
        (, uint256 quoteTarget) = dodoPair.getExpectedTarget();
        (uint256 stakedLpAmount, ) = IDODOMine(dodoMine).userInfo(IDODOMine(dodoMine).getPid(lpToken), address(this));
        return ((stakedLpAmount + dodoPair.getQuoteCapitalBalanceOf(address(this))) * quoteTarget) / totalQuoteCapital;
    }
}
