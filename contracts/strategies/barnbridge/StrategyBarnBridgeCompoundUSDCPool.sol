// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../base/AbstractStrategy.sol";
import "./interfaces/IISmartYield.sol";
import "./interfaces/IYieldFarmSingle.sol";
import "./dependencies/yield-farm-continuous/YieldFarmContinuous.sol";
import "../uniswap-v2/interfaces/IUniswapV2Router02.sol";

contract StrategyBarnBridgeCompoundUSDCPool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of junior token(bb_cUSDC)
    address public immutable jToken;

    // The latest stored junior token price
    uint256 public latestJTokenPrice;

    // The address of provider which sends supply token to compound leding pool
    address public immutable provider;

    // The symbol of supply token
    string public constant symbol = 'USDC';

    // The address of BarnBridge yield farm
    address public immutable yieldFarm;
    YieldFarmContinuous immutable yieldFarmContract;

    // The address of BarnBridge governance token
    address public constant bond = address(0x0391D2021f89DC339F60Fff84546EA23E337750f);

    // The address of WETH
    address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // The address of the Uniswap V2 router
    address public constant uniswap = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    constructor(
        address _jToken,
        address _provider,
        address _yieldFarm,
        address _supplyToken,
        address _controller
    ) AbstractStrategy(_controller, _supplyToken) {
        jToken = _jToken;
        provider = _provider;
        yieldFarm = _yieldFarm;
        yieldFarmContract = YieldFarmContinuous(_yieldFarm);
    }

    /**
     * @dev Require that the caller must be an EOA account to avoid flash loans.
     */
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Not EOA");
        _;
    }

    function getAssetAmount() public view override returns (uint256) {
        uint256 jTokenBalance = yieldFarmContract.balances(address(this));
        // Calculate share of jTokenBalance in the debt
        uint256 forfeits = calForfeits(jTokenBalance);
        return (jTokenBalance * latestJTokenPrice) / 1e18 - forfeits;
    }

    function calForfeits(uint256 jTokenAmount) public view returns (uint256) {
        // share of jTokenAmount in the debt
        uint256 debtShare = (jTokenAmount * 1e18) / IERC20(jToken).totalSupply();
        uint256 forfeits = (IISmartYield(jToken).abondDebt() * debtShare) / 1e18;
        return forfeits;
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        // Store junior token price every rollup chain calls aggregateOrders()
        latestJTokenPrice = IISmartYield(jToken).price();

        uint256 originalAssetAmount = getAssetAmount();

        // Pull supplying token from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // Buy junior token
        IERC20(supplyToken).safeIncreaseAllowance(provider, _buyAmount);
        IISmartYield(jToken).buyTokens(
            _buyAmount,
            uint256(0),
            block.timestamp + 1800
        );

        // Stake junior token to yieldFarmContract for earn BOND token
        uint256 jTokenBalance = IERC20(jToken).balanceOf(address(this));
        IERC20(jToken).safeIncreaseAllowance(yieldFarm, jTokenBalance);
        IYieldFarmSingle(yieldFarm).deposit(jTokenBalance);

        uint256 newAssetAmount = getAssetAmount();
        return newAssetAmount - originalAssetAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        // Store junior token price every rollup chain calls aggregateOrders()
        latestJTokenPrice = IISmartYield(jToken).price();

        uint256 balanceBeforeSell = IERC20(supplyToken).balanceOf(address(this));

        // Unstake junior token(bb_cUSDC) from Yield Farm
        uint256 jTokenWithdrawAmount = (_sellAmount * 1e18) / latestJTokenPrice;
        IYieldFarmSingle(yieldFarm).withdraw(jTokenWithdrawAmount);

        // Instant withdraw
        IISmartYield(jToken).sellTokens(
          jTokenWithdrawAmount,
          uint256(0),
          block.timestamp + 1800
        );

        // Transfer supplying token to Controller
        uint256 balanceAfterSell = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, balanceAfterSell);

        return balanceAfterSell - balanceBeforeSell;
    }

    function harvest() external override onlyEOA {
        IYieldFarmSingle(yieldFarm).claim();
        uint256 bondBalance = IERC20(bond).balanceOf(address(this));
        if (bondBalance > 0) {
            // Sell BOND for more supplying token
            IERC20(bond).safeIncreaseAllowance(uniswap, bondBalance);

            address[] memory paths = new address[](3);
            paths[0] = bond;
            paths[1] = weth;
            paths[2] = supplyToken;

            IUniswapV2Router02(uniswap).swapExactTokensForTokens(
                bondBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp + 1800
            );

            uint256 obtainedSupplyTokenAmount = IERC20(supplyToken).balanceOf(address(this));
            IERC20(supplyToken).safeIncreaseAllowance(provider, obtainedSupplyTokenAmount);
            IISmartYield(jToken).buyTokens(
                obtainedSupplyTokenAmount,
                uint256(0),
                block.timestamp + 1800
            );

            // Stake junior token to yieldFarmContract for earn BOND token
            uint256 jTokenBalance = IERC20(jToken).balanceOf(address(this));
            IERC20(jToken).safeIncreaseAllowance(yieldFarm, jTokenBalance);
            IYieldFarmSingle(yieldFarm).deposit(jTokenBalance);
        }
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = jToken;
        protected[1] = bond;
        return protected;
    }
}
