// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


import "../uniswap-v2/interfaces/IUniswapV2Router02.sol";
import "../aave/interfaces/IStakedAave.sol";
import "./interfaces/IIdleToken.sol";
import "./GovTokenRegistry.sol";
import "../base/AbstractStrategy.sol";

contract StrategyIdleLendingPool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // Governance token registry
    GovTokenRegistry govTokenRegistry;

    // The address of Idle Lending Pool(e.g. IdleDAI, IdleUSDC)
    address public iToken;

    // Info of supplying erc20 token to Aave lending pool
    // The symbol of the supplying token
    string public symbol;
    uint256 public supplyTokenDecimal;

    // The address of Aave StakedAave contract
    address public stakedAave;

    address public weth;
    address public sushiswap;

    uint256 constant public FULL_ALLOC = 100000;

    constructor(
        address _iToken,
        string memory _symbol,
        address _supplyToken,
        uint8 _supplyTokenDecimal,
        address _govTokenRegistryAddress,
        address _stakedAave,
        address _weth,
        address _sushiswap,
        address _controller
    ) AbstractStrategy(_controller, _supplyToken) {
        iToken = _iToken;
        symbol = _symbol;
        supplyToken = _supplyToken;
        supplyTokenDecimal = _supplyTokenDecimal;
        govTokenRegistry = GovTokenRegistry(_govTokenRegistryAddress);
        stakedAave = _stakedAave;
        weth = _weth;
        sushiswap = _sushiswap;
    }

    function getAssetAmount() internal view override returns (uint256) {
        uint256 iTokenBalance = IERC20(iToken).balanceOf(address(this));
        return ((iTokenBalance * tokenPriceWithFee()) / (10**supplyTokenDecimal)) / (10**(18 - supplyTokenDecimal));
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        // Pull supply token from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);

        // Deposit supply token to Idle Lending Pool
        IERC20(supplyToken).safeIncreaseAllowance(iToken, _buyAmount);
        uint256 iTokenMintedAmount = IIdleToken(iToken).mintIdleToken(_buyAmount, false, address(0));
        uint256 obtainedUnderlyingAsset = ((iTokenMintedAmount * IIdleToken(iToken).tokenPrice()) / (10**supplyTokenDecimal)) / (10**(18 - supplyTokenDecimal));
        return obtainedUnderlyingAsset;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        // Redeem supply token amount + interests and claim governance tokens
        // When `harvest` function is called, this contract lend obtained governance token to save gas
        uint256 iTokenBurnAmount = ((_sellAmount * (10**supplyTokenDecimal)) / tokenPriceWithFee()) * (10**(18 - supplyTokenDecimal));
        IIdleToken(iToken).redeemIdleToken(iTokenBurnAmount);

        // Transfer supply token to Controller
        uint256 obtainedSupplyTokenAmount = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeTransfer(msg.sender, obtainedSupplyTokenAmount);

        return obtainedSupplyTokenAmount;
    }

    function harvest() external override onlyOwnerOrController {
        // Claim governance tokens without redeeming supply token
        IIdleToken(iToken).redeemIdleToken(uint256(0));

        harvestAAVE();
        swapGovTokensToSupplyToken();

        // Deposit obtained supply token to Idle Lending Pool
        uint256 obtainedSupplyTokenAmount = IERC20(supplyToken).balanceOf(address(this));
        IERC20(supplyToken).safeIncreaseAllowance(iToken, obtainedSupplyTokenAmount);
        IIdleToken(iToken).mintIdleToken(obtainedSupplyTokenAmount, false, address(0));
    }

    // Refer to IdleTokenGovernance.sol (https://github.com/Idle-Labs/idle-contracts/blob/develop/contracts/IdleTokenGovernance.sol#L340)
    function tokenPriceWithFee() public view returns (uint256) {
        uint256 userAvgPrice = IIdleToken(iToken).userAvgPrices(address(this));
        uint256 priceWFee = IIdleToken(iToken).tokenPrice();
        uint256 fee = IIdleToken(iToken).fee();
        if (userAvgPrice != 0 && priceWFee > userAvgPrice) {
            priceWFee = ((priceWFee * (FULL_ALLOC)) - (fee * (priceWFee - userAvgPrice))) / FULL_ALLOC;
        }
        return priceWFee;
    }

    function harvestAAVE() private {
        // Idle finance transfer stkAAVE to this contract
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
            cooldownStartTimestamp + IStakedAave(stakedAave).COOLDOWN_SECONDS() + IStakedAave(stakedAave).UNSTAKE_WINDOW()
        ) {
            IStakedAave(stakedAave).redeem(address(this), stakedAaveBalance);
        }
    }

    function swapGovTokensToSupplyToken() private {
        uint govTokenLength = govTokenRegistry.getGovTokensLength();
        address[] memory govTokens = govTokenRegistry.getGovTokens();
        for(uint32 i = 0; i < govTokenLength; i++) {
            uint256 govTokenBalance = IERC20(govTokens[i]).balanceOf(address(this));
            if (govTokenBalance > 0) {
                IERC20(govTokens[i]).safeIncreaseAllowance(sushiswap, govTokenBalance);
                if (supplyToken != weth) {
                    address[] memory paths = new address[](3);
                    paths[0] = govTokens[i];
                    paths[1] = weth;
                    paths[2] = supplyToken;

                    IUniswapV2Router02(sushiswap).swapExactTokensForTokens(
                        govTokenBalance,
                        uint(0),
                        paths,
                        address(this),
                        block.timestamp + 1800
                    );
                } else {
                    address[] memory paths = new address[](2);
                    paths[0] = govTokens[i];
                    paths[1] = weth;

                    IUniswapV2Router02(sushiswap).swapExactTokensForTokens(
                        govTokenBalance,
                        uint(0),
                        paths,
                        address(this),
                        block.timestamp + 1800
                    );
                }
            }
        }
    }
}
