// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../AbstractStrategy.sol";
import "../interfaces/uniswap/IUniswapV2.sol";
import "../interfaces/liquity/IBorrowerOperations.sol";
import "../interfaces/liquity/IHintHelpers.sol";
import "../interfaces/liquity/ISortedTroves.sol";
import "../interfaces/liquity/IStabilityPool.sol";
import "../interfaces/liquity/ITroveManager.sol";
import "../interfaces/liquity/IPriceFeed.sol";
import "../../interfaces/IWETH.sol";

/**
 * Deposits ETH into Liquity Protocal, opens a trove to borrow LUSD, stakes LUSD to stability pool to yield mining.
 */
contract StrategyLiquityPool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    address public uniswap;
    address public lqty;

    // Liqutity contracts
    address public borrowerOperations;
    address public stabilityPool;
    address public hintHelpers;
    address public sortedTroves;
    address public troveManager;
    address public priceFeed;

    uint256 public icrInitial; // e.g. 3 * 1e18
    uint256 public icrUpperLimit; // e.g. 3.2 * 1e18
    uint256 public icrLowerLimit; // e.g. 2.5 * 1e18

    // in the Liquity operations, the max fee percentage we are willing to accept in case of a fee slippage
    uint256 public maxFeePercentage;
    uint256 internal constant NICR_PRECISION = 1e20;
    // Minimum amount of net LUSD debt a trove must have
    uint256 internal constant MIN_NET_DEBT = 1950e18;

    constructor(
        address _controller,
        address _weth, // weth as supply token
        address _uniswap,
        address _lqty,
        address[6] memory _liquityContracts,
        uint256 _icrInitial,
        uint256 _icrUpperLimit,
        uint256 _icrLowerLimit,
        uint256 _maxFeePercentage
    ) AbstractStrategy(_controller, _weth) {
        require(
            _icrInitial < _icrUpperLimit && _icrInitial > _icrLowerLimit, 
            "icrInitial should be between icrLowerLimit and icrUpperLimit!"
        );
        uniswap = _uniswap;
        lqty = _lqty;
        borrowerOperations = _liquityContracts[0];
        stabilityPool = _liquityContracts[1];
        hintHelpers = _liquityContracts[2];
        sortedTroves = _liquityContracts[3];
        troveManager = _liquityContracts[4];
        priceFeed = _liquityContracts[5];
        icrInitial = _icrInitial;
        icrUpperLimit = _icrUpperLimit;
        icrLowerLimit = _icrLowerLimit;
        maxFeePercentage = _maxFeePercentage;
    }

    /**
     * @dev Require that the caller must be an EOA account to avoid flash loans.
     */
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Not EOA");
        _;
    }

    function getAssetAmount() internal view override returns (uint256) {
        uint256 assetAmount;
        (,assetAmount,,) = ITroveManager(troveManager).getEntireDebtAndColl(address(this));
        return assetAmount;
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        // Pull WETH from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);
        // Convert WETH into ETH
        IWETH(supplyToken).withdraw(_buyAmount);

        uint256 originalAssetAmount = getAssetAmount();
        if (ITroveManager(troveManager).getTroveStatus(address(this)) != 1) {
            (address upperHint, address lowerHint) = _getHints(MAX_INT);
            // Borrow allowed minimum LUSD, CR will be adjusted later.
            IBorrowerOperations(borrowerOperations).openTrove{value: _buyAmount}(maxFeePercentage, MIN_NET_DEBT, upperHint, lowerHint);
        } else {
            (uint256 debt,uint256 coll,,) = ITroveManager(troveManager).getEntireDebtAndColl(address(this));
            uint256 nicr = MAX_INT;
            if (debt != 0) {
                nicr = (coll + _buyAmount) * NICR_PRECISION / debt;
            }
            (address upperHint, address lowerHint) = _getHints(nicr);
            IBorrowerOperations(borrowerOperations).addColl{value: _buyAmount}(upperHint, lowerHint);
        }

        uint256 newAssetAmount = getAssetAmount();
        _monitorAndAdjustCR();
        
        return newAssetAmount - originalAssetAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        // here just withdrawal collateral, CR will be adjusted later
        (uint256 debt,uint256 coll,,) = ITroveManager(troveManager).getEntireDebtAndColl(address(this));
        uint256 nicr = MAX_INT;
        if (debt != 0) {
            nicr = (coll - _sellAmount) * NICR_PRECISION / debt;
        }
        (address upperHint, address lowerHint) = _getHints(nicr);

        uint256 balanceBeforeSell = address(this).balance;
        IBorrowerOperations(borrowerOperations).withdrawColl(_sellAmount, upperHint, lowerHint);

        // Convert ETH into WETH
        uint256 balanceAfterSell = address(this).balance;
        IWETH(supplyToken).deposit{value: balanceAfterSell}();
        // Transfer WETH to Controller
        IERC20(supplyToken).safeTransfer(msg.sender, balanceAfterSell);

        _monitorAndAdjustCR();

        return balanceAfterSell - balanceBeforeSell;
    }

    function _getHints(uint256 _ncr) private view returns (address, address) {
        return (address(this), address(this));
        // uint256 numTroves = ISortedTroves(sortedTroves).getSize();
        // uint256 numTrials = numTroves.mul(15);
        // (address approxHint,,) = IHintHelpers(hintHelpers).getApproxHint(_ncr, numTrials, 42);
        // return ISortedTroves(sortedTroves).findInsertPosition(_ncr, approxHint, approxHint);
    }

    /* 
     * Continuously monitor the collateral ratio
     * If collateral ratio is smaller than icrLowerLimit, withdrawal LUSD from stability pool and repay the debt to rebalance CR back to 300%
     * If collateral ratio is larger than icrUpperLimit, generate more LUSD from the trove and stake to Stability Pool and bring CR back to 300%
     */
    function _monitorAndAdjustCR() private {
        uint256 currentEthPrice = IPriceFeed(priceFeed).fetchPrice();
        uint256 currentICR = ITroveManager(troveManager).getCurrentICR(address(this), currentEthPrice);
        if (currentICR < icrLowerLimit) {
            (uint256 debt,uint256 coll,,) = ITroveManager(troveManager).getEntireDebtAndColl(address(this));
            uint256 expectDebt = debt * currentICR / icrInitial;
            
            uint256 nicr = coll * NICR_PRECISION / expectDebt;
            (address upperHint, address lowerHint) = _getHints(nicr);

            // TODO: make sure the LUSD in the stability pool is enough to withdrawal;
            IStabilityPool(stabilityPool).withdrawFromSP(debt - expectDebt);
            IBorrowerOperations(borrowerOperations).repayLUSD(debt - expectDebt, upperHint, lowerHint);
        } else if (currentICR > icrUpperLimit) {
            (uint256 debt,uint256 coll,,) = ITroveManager(troveManager).getEntireDebtAndColl(address(this));
            uint256 expectDebt = coll * currentEthPrice / icrInitial;

            uint256 nicr = coll * NICR_PRECISION / expectDebt;
            (address upperHint, address lowerHint) = _getHints(nicr);

            IBorrowerOperations(borrowerOperations).withdrawLUSD(maxFeePercentage, expectDebt - debt, upperHint, lowerHint);
            IStabilityPool(stabilityPool).provideToSP(expectDebt - debt, address(0));
        }
    }

    function harvest() external override onlyEOA {
        (address upperHint, address lowerHint) = _getHints(ITroveManager(troveManager).getNominalICR(address(this)));
        IStabilityPool(stabilityPool).withdrawETHGainToTrove(upperHint, lowerHint);

        // Sell LQTY that was rewarded each time when deposit/withdrawal or timebased etc.
        uint256 lqtyBalance = IERC20(lqty).balanceOf(address(this));
        if (lqtyBalance > 0) {
            IERC20(lqty).safeIncreaseAllowance(uniswap, lqtyBalance);

            address[] memory paths = new address[](2);
            paths[0] = lqty;
            paths[1] = supplyToken;

            IUniswapV2(uniswap).swapExactTokensForETH(
                lqtyBalance,
                uint256(0),
                paths,
                address(this),
                block.timestamp + 1800
            );

            // add ETH to trove
            uint256 obtainedEthAmount = address(this).balance;
            IBorrowerOperations(borrowerOperations).addColl{value: obtainedEthAmount}(upperHint, lowerHint);
        }

        _monitorAndAdjustCR();
    }

    // This is needed to receive ETH
    receive() external payable {}

    fallback() external payable {}
}
