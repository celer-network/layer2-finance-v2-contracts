// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../AbstractStrategy.sol";
import "../interfaces/aave/ILendingPool.sol";
import "../interfaces/aave/IAToken.sol";
import "../interfaces/aave/IAaveIncentivesController.sol";
import "../interfaces/aave/IStakedAave.sol";
import "../interfaces/uniswap/IUniswapV2.sol";

/**
 * Deposits ERC20 token into Aave Lending Pool and issues stAaveLendingToken(e.g. stAaveLendingDAI) in L2. Holds aToken (Aave interest-bearing tokens).
 */
contract StrategyAaveLendingPool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of Aave Lending Pool
    address public lendingPool;

    // The address of Aave interest-bearing token (e.g. aDAI, aUSDT)
    address public aToken;

    // The address of Aave Incentives Controller
    address public incentivesController;

    // The address of Aave StakedAave contract
    address public stakedAave;

    // The address of AAVE token
    address public aave;

    address public uniswap;
    // The address of WETH token
    address public weth;

    constructor(
        address _lendingPool,
        address _supplyToken,
        address _aToken,
        address _controller,
        address _incentivesController,
        address _stakedAave,
        address _aave,
        address _uniswap,
        address _weth
    ) AbstractStrategy(_controller, _supplyToken) {
        lendingPool = _lendingPool;
        aToken = _aToken;
        incentivesController = _incentivesController;
        stakedAave = _stakedAave;
        aave = _aave;
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

    function getAssetAmount() internal view override returns (uint256) {
        return IAToken(aToken).balanceOf(address(this));
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        uint256 originalAssetAmount = getAssetAmount();

        // Pull supplying token(e.g. DAI, USDT) from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);
        // Deposit supplying token to Aave Lending Pool and mint aToken.
        IERC20(supplyToken).safeIncreaseAllowance(lendingPool, _buyAmount);
        ILendingPool(lendingPool).deposit(supplyToken, _buyAmount, address(this), 0);

        uint256 newAssetAmount = getAssetAmount();
        
        return newAssetAmount - originalAssetAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        uint256 balanceBeforeSell = IERC20(supplyToken).balanceOf(address(this));
        
        // Withdraw supplying token(e.g. DAI, USDT) from Aave Lending Pool.
        ILendingPool(lendingPool).withdraw(supplyToken, _sellAmount, address(this));
        // Transfer supplying token to Controller
        uint256 balanceAfterSell = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, balanceAfterSell);

        return balanceAfterSell - balanceBeforeSell;
    }

    function harvest() external override onlyEOA {
        // 1. Claims the liquidity incentives
        address[] memory assets = new address[](1);
        assets[0] = aToken;
        uint256 rewardsBalance =
            IAaveIncentivesController(incentivesController).getRewardsBalance(assets, address(this));
        if (rewardsBalance > 0) {
            IAaveIncentivesController(incentivesController).claimRewards(assets, rewardsBalance, address(this));
        }

        // 2. Activates the cooldown period if not already activated
        uint256 stakedAaveBalance = IERC20(stakedAave).balanceOf(address(this));
        if (stakedAaveBalance > 0 && IStakedAave(stakedAave).stakersCooldowns(address(this)) == 0) {
            IStakedAave(stakedAave).cooldown();
        }

        // 3. Claims the AAVE staking rewards
        uint256 stakingRewards = IStakedAave(stakedAave).getTotalRewardsBalance(address(this));
        if (stakingRewards > 0) {
            IStakedAave(stakedAave).claimRewards(address(this), stakingRewards);
        }

        // 4. Redeems staked AAVE if possible
        uint256 cooldownStartTimestamp = IStakedAave(stakedAave).stakersCooldowns(address(this));
        if (
            stakedAaveBalance > 0 &&
            block.timestamp > cooldownStartTimestamp + IStakedAave(stakedAave).COOLDOWN_SECONDS() &&
            block.timestamp <=
            cooldownStartTimestamp + IStakedAave(stakedAave).COOLDOWN_SECONDS() + IStakedAave(stakedAave).UNSTAKE_WINDOW()
        ) {
            IStakedAave(stakedAave).redeem(address(this), stakedAaveBalance);
        }

        // 5. Sells the reward AAVE token and the redeemed staked AAVE for obtain more supplying token
        uint256 aaveBalance = IERC20(aave).balanceOf(address(this));
        if (aaveBalance > 0) {
            IERC20(aave).safeIncreaseAllowance(uniswap, aaveBalance);

            address[] memory paths = new address[](3);
            paths[0] = aave;
            paths[1] = weth;
            paths[2] = supplyToken;

            IUniswapV2(uniswap).swapExactTokensForTokens(
                aaveBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp + 1800
            );

            // Deposit supplying token to Aave Lending Pool and mint aToken.
            uint256 obtainedSupplyTokenAmount = IERC20(supplyToken).balanceOf(address(this));
            IERC20(supplyToken).safeIncreaseAllowance(lendingPool, obtainedSupplyTokenAmount);
            ILendingPool(lendingPool).deposit(supplyToken, obtainedSupplyTokenAmount, address(this), 0);
        }
    }
}
