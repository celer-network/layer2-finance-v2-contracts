// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../base/AbstractStrategy.sol";
import "./interfaces/IISmartYield.sol";
import "./interfaces/IYieldFarmMulti.sol";
import "./dependencies/multi-reward-token/PoolMulti.sol";
import "../uniswap-v2/interfaces/IUniswapV2Router02.sol";
import "../aave/interfaces/IStakedAave.sol";

contract StrategyBarnBridgeAavePool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of junior token(e.g. bb_aDAI,bb_aUSDC)
    address public immutable jToken;

    // The latest stored junior token price
    uint256 public latestJTokenPrice;

    // The address of provider which sends supply token to aave leding pool
    address public immutable provider;

    // The symbol of supply token
    string public symbol;

    // The address of BarnBridge yield farm
    address public immutable yieldFarm;
    PoolMulti immutable yieldFarmContract;

    // The address of BarnBridge governance token
    address public constant bond = address(0x0391D2021f89DC339F60Fff84546EA23E337750f);

    // The address of Aave token
    address public constant aave = address(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
    // The address of Aave StakedAave contract
    address public constant stakedAave = address(0x4da27a545c0c5B758a6BA100e3a049001de870f5);

    // The address of WETH
    address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // The address of the Uniswap V2 router
    address public constant uniswap = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    constructor(
        address _jToken,
        address _provider,
        string memory _symbol,
        address _yieldFarm,
        address _supplyToken,
        address _controller
    ) AbstractStrategy(_controller, _supplyToken) {
        jToken = _jToken;
        provider = _provider;
        symbol = _symbol;
        yieldFarm = _yieldFarm;
        yieldFarmContract = PoolMulti(_yieldFarm);
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
        IYieldFarmMulti(yieldFarm).deposit(jTokenBalance);

        uint256 newAssetAmount = getAssetAmount();
        return newAssetAmount - originalAssetAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        // Store junior token price every rollup chain calls aggregateOrders()
        latestJTokenPrice = IISmartYield(jToken).price();

        uint256 balanceBeforeSell = IERC20(supplyToken).balanceOf(address(this));

        // Unstake junior token(e.g. bb_aUSDC, bb_aDAI) from Yield Farm
        uint256 jTokenWithdrawAmount = (_sellAmount * 1e18) / latestJTokenPrice;
        IYieldFarmMulti(yieldFarm).withdraw(jTokenWithdrawAmount);

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
        // Claim Bond and AAVE
        IYieldFarmMulti(yieldFarm).claim_allTokens();
        harvestAAVE();

        swapGovTokensToSupplyToken();

        uint256 obtainedSupplyTokenAmount = IERC20(supplyToken).balanceOf(address(this));
        if (obtainedSupplyTokenAmount > 0) {
            IERC20(supplyToken).safeIncreaseAllowance(provider, obtainedSupplyTokenAmount);
            IISmartYield(jToken).buyTokens(
                obtainedSupplyTokenAmount,
                uint256(0),
                block.timestamp + 1800
            );

            // Stake junior token to yieldFarmContract for earn BOND token
            uint256 jTokenBalance = IERC20(jToken).balanceOf(address(this));
            IERC20(jToken).safeIncreaseAllowance(yieldFarm, jTokenBalance);
            IYieldFarmMulti(yieldFarm).deposit(jTokenBalance);
        }
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](3);
        protected[0] = jToken;
        protected[1] = bond;
        protected[3] = aave;
        return protected;
    }

    function harvestAAVE() private {
        // Activates the cooldown period if not already activated
        uint256 stakedAaveBalance = IERC20(stakedAave).balanceOf(address(this));
        if (stakedAaveBalance > 0 && IStakedAave(stakedAave).stakersCooldowns(address(this)) == 0) {
            IStakedAave(stakedAave).cooldown();
        }

        // Claims the AAVE staking rewards
        uint256 stakingRewards = IStakedAave(stakedAave).getTotalRewardsBalance(address(this));
        if (stakingRewards > 0) {
            IStakedAave(stakedAave).claimRewards(address(this), stakingRewards);
        }

        // Redeems staked AAVE if possible
        uint256 cooldownStartTimestamp = IStakedAave(stakedAave).stakersCooldowns(address(this));
        if (
            stakedAaveBalance > 0 &&
            block.timestamp > cooldownStartTimestamp + IStakedAave(stakedAave).COOLDOWN_SECONDS() &&
            block.timestamp <=
            cooldownStartTimestamp +
                IStakedAave(stakedAave).COOLDOWN_SECONDS() +
                IStakedAave(stakedAave).UNSTAKE_WINDOW()
        ) {
            IStakedAave(stakedAave).redeem(address(this), stakedAaveBalance);
        }
    }

    function swapGovTokensToSupplyToken() private {
      uint256 bondBalance = IERC20(bond).balanceOf(address(this));
      address[] memory paths = new address[](3);
      if (bondBalance > 0) {
          // Sell BOND for more supplying token
          IERC20(bond).safeIncreaseAllowance(uniswap, bondBalance);

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
      }

      uint256 aaveBalance = IERC20(aave).balanceOf(address(this));
      if (aaveBalance > 0) {
          // Sell Aave for more supplying token
          IERC20(aave).safeIncreaseAllowance(uniswap, aaveBalance);

          paths[0] = aave;
          paths[1] = weth;
          paths[2] = supplyToken;

          IUniswapV2Router02(uniswap).swapExactTokensForTokens(
               aaveBalance,
               uint256(0),
               paths,
               address(this),
               block.timestamp + 1800
          );
      }
    }
}
