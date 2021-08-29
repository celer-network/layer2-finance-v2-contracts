// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "../../interfaces/IWETH.sol";
import "../base/AbstractStrategy.sol";
import "./interfaces/IBorrowerOperations.sol";
import "./interfaces/IHintHelpers.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/ISortedTroves.sol";
import "./interfaces/IStabilityPool.sol";
import "./interfaces/ITroveManager.sol";

/**
 * Deposits ETH into Liquity Protocol, opens a trove to borrow LUSD, stakes LUSD to stability pool to yield mining.
 */
contract StrategyLiquityPool is AbstractStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // The address of the Uniswap V3 router
    address public immutable swapRouter;

    // The address of the LQTY token
    address public immutable lqty;
    // The address of the LUSD token
    address public immutable lusd;

    // Liquity contracts
    address public immutable borrowerOperations;
    address public immutable stabilityPool;
    address public immutable hintHelpers;
    address public immutable sortedTroves;
    address public immutable troveManager;
    address public immutable priceFeed;

    // Params for Individual Collateralization Ratio (ICR)
    uint256 public icrInitial; // e.g. 3 * 1e18
    uint256 public icrUpperLimit; // e.g. 3.2 * 1e18
    uint256 public icrLowerLimit; // e.g. 2.5 * 1e18

    // In Liquity operations, the max fee percentage we are willing to accept in case of a fee slippage
    uint256 public maxFeePercentage;

    // Params for Hints
    uint256 public maxNumHintTrials = 100;
    bool public useManualHints;
    address public manualUpperHint;
    address public manualLowerHint;

    // Debt used to calculate NICR when opening a Trove
    bool public useManualOpenDebt;
    uint256 public manualOpenDebt;

    uint256 internal constant NICR_PRECISION = 1e20;
    uint256 internal constant HINT_K = 15;
    uint24 internal constant SWAP_FEE = 3000;

    constructor(
        address _controller,
        address _swapRouter,
        address _weth, // WETH as supply token
        address _lusd,
        address _lqty,
        address[6] memory _liquityContracts,
        uint256 _icrInitial,
        uint256 _icrUpperLimit,
        uint256 _icrLowerLimit,
        uint256 _maxFeePercentage
    ) AbstractStrategy(_controller, _weth) onlyValidICR(_icrInitial, _icrUpperLimit, _icrLowerLimit) {
        swapRouter = _swapRouter;
        lqty = _lqty;
        lusd = _lusd;
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

    modifier onlyValidICR(
        uint256 _icrInitial,
        uint256 _icrUpperLimit,
        uint256 _icrLowerLimit
    ) {
        require(
            _icrInitial < _icrUpperLimit && _icrInitial > _icrLowerLimit,
            "icrInitial should be between icrLowerLimit and icrUpperLimit!"
        );
        _;
    }

    function getAssetAmount() public view override returns (uint256) {
        uint256 assetAmount;
        (, assetAmount, , ) = ITroveManager(troveManager).getEntireDebtAndColl(address(this));
        return assetAmount;
    }

    function buy(uint256 _buyAmount) internal override returns (uint256) {
        // Pull WETH from Controller
        IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), _buyAmount);
        // Convert WETH into ETH
        IWETH(supplyToken).withdraw(_buyAmount);

        uint256 originalAssetAmount = getAssetAmount();
        if (ITroveManager(troveManager).getTroveStatus(address(this)) != uint256(ITroveManager.Status.active)) {
            uint256 minNetDebt = ITroveManager(troveManager).MIN_NET_DEBT();
            uint256 expectedDebt;
            if (useManualOpenDebt) {
                expectedDebt = manualOpenDebt;
            } else {
                // Call deployed TroveManager contract to read the liquidation reserve and latest borrowing fee
                uint256 liquidationReserve = ITroveManager(troveManager).LUSD_GAS_COMPENSATION();
                uint256 expectedFee = ITroveManager(troveManager).getBorrowingFeeWithDecay(minNetDebt);
                // Total debt of the new trove = LUSD amount drawn, plus fee, plus the liquidation reserve
                expectedDebt = minNetDebt + expectedFee + liquidationReserve;
            }
            // Get the nominal NICR of the new trove
            uint256 nicr = (_buyAmount * NICR_PRECISION) / expectedDebt;
            (address upperHint, address lowerHint) = _getHints(nicr);
            // Borrow allowed minimum LUSD, CR will be adjusted later.
            IBorrowerOperations(borrowerOperations).openTrove{value: _buyAmount}(
                maxFeePercentage,
                minNetDebt,
                upperHint,
                lowerHint
            );
        } else {
            (uint256 debt, uint256 coll, , ) = ITroveManager(troveManager).getEntireDebtAndColl(address(this));
            if (debt == 0) {
                debt = ITroveManager(troveManager).MIN_NET_DEBT();
            }
            uint256 nicr = ((coll + _buyAmount) * NICR_PRECISION) / debt;
            (address upperHint, address lowerHint) = _getHints(nicr);
            IBorrowerOperations(borrowerOperations).addColl{value: _buyAmount}(upperHint, lowerHint);
        }

        uint256 newAssetAmount = getAssetAmount();
        _monitorAndAdjustCR();

        return newAssetAmount - originalAssetAmount;
    }

    function sell(uint256 _sellAmount) internal override returns (uint256) {
        // here just withdrawal collateral, CR will be adjusted later
        (uint256 debt, uint256 coll, , ) = ITroveManager(troveManager).getEntireDebtAndColl(address(this));
        if (debt == 0) {
            debt = ITroveManager(troveManager).MIN_NET_DEBT();
        }
        uint256 nicr = ((coll - _sellAmount) * NICR_PRECISION) / debt;
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

    function _getHints(uint256 _nicr) private view returns (address, address) {
        if (useManualHints) {
            return (manualUpperHint, manualLowerHint);
        }
        uint256 numTroves = ISortedTroves(sortedTroves).getSize();
        uint256 numTrials = HINT_K * numTroves;
        if (numTrials > maxNumHintTrials) {
            numTrials = maxNumHintTrials;
        }
        (address approxHint, , ) = IHintHelpers(hintHelpers).getApproxHint(_nicr, numTrials, block.timestamp);
        return ISortedTroves(sortedTroves).findInsertPosition(_nicr, approxHint, approxHint);
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
            (uint256 debt, uint256 coll, , ) = ITroveManager(troveManager).getEntireDebtAndColl(address(this));
            uint256 expectDebt = (debt * currentICR) / icrInitial;

            uint256 nicr = (coll * NICR_PRECISION) / expectDebt;
            (address upperHint, address lowerHint) = _getHints(nicr);

            // TODO: make sure the LUSD in the stability pool is enough to withdrawal;
            IStabilityPool(stabilityPool).withdrawFromSP(debt - expectDebt);
            IBorrowerOperations(borrowerOperations).repayLUSD(debt - expectDebt, upperHint, lowerHint);
        } else if (currentICR > icrUpperLimit) {
            (uint256 debt, uint256 coll, , ) = ITroveManager(troveManager).getEntireDebtAndColl(address(this));
            uint256 expectDebt = (coll * currentEthPrice) / icrInitial;

            uint256 nicr = (coll * NICR_PRECISION) / expectDebt;
            (address upperHint, address lowerHint) = _getHints(nicr);

            IBorrowerOperations(borrowerOperations).withdrawLUSD(
                maxFeePercentage,
                expectDebt - debt,
                upperHint,
                lowerHint
            );
            IStabilityPool(stabilityPool).provideToSP(expectDebt - debt, address(0));
        }
    }

    function harvest() external override onlyEOA {
        (address upperHint, address lowerHint) = _getHints(ITroveManager(troveManager).getNominalICR(address(this)));
        uint256 ethGain = IStabilityPool(stabilityPool).getDepositorETHGain(address(this));
        if (ethGain > 0) {
            IStabilityPool(stabilityPool).withdrawETHGainToTrove(upperHint, lowerHint);
        }

        // Sell LQTY that was rewarded each time when deposit / withdrawal or time-based etc.
        uint256 lqtyBalance = IERC20(lqty).balanceOf(address(this));
        if (lqtyBalance > 0) {
            address tokenIn = lqty;
            address tokenOut = supplyToken;
            uint256 amountIn = lqtyBalance;
            // TODO: Check price
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: SWAP_FEE,
                recipient: address(this),
                deadline: block.timestamp + 1800,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            IERC20(tokenIn).safeIncreaseAllowance(swapRouter, amountIn);
            ISwapRouter(swapRouter).exactInputSingle(params);
            uint256 obtainedEthAmount = IERC20(supplyToken).balanceOf(address(this));
            IWETH(supplyToken).withdraw(obtainedEthAmount);

            // Add ETH to trove
            IBorrowerOperations(borrowerOperations).addColl{value: obtainedEthAmount}(upperHint, lowerHint);
        }

        _monitorAndAdjustCR();
    }

    function adjust() external override onlyEOA {
        _monitorAndAdjustCR();
    }

    function setICR(
        uint256 _icrInitial,
        uint256 _icrUpperLimit,
        uint256 _icrLowerLimit
    ) external onlyOwner onlyValidICR(_icrInitial, _icrUpperLimit, _icrLowerLimit) {
        icrInitial = _icrInitial;
        icrUpperLimit = _icrUpperLimit;
        icrLowerLimit = _icrLowerLimit;
    }

    function setMaxFeePercentage(uint256 _maxFeePercentage) external onlyOwner {
        maxFeePercentage = _maxFeePercentage;
    }

    function setMaxNumHintTrials(uint256 _maxNumHintTrials) external onlyOwner {
        maxNumHintTrials = _maxNumHintTrials;
    }

    function setManualHints(
        bool _useManualHints,
        address _manualUpperHint,
        address _manualLowerHint
    ) external onlyOwner {
        useManualHints = _useManualHints;
        manualUpperHint = _manualUpperHint;
        manualLowerHint = _manualLowerHint;
    }

    function setManualOpenDebt(bool _useManualOpenDebt, uint256 _manualOpenDebt) external onlyOwner {
        useManualOpenDebt = _useManualOpenDebt;
        manualOpenDebt = _manualOpenDebt;
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = lusd;
        protected[1] = lqty;
        return protected;
    }

    // This is needed to receive ETH
    receive() external payable {}

    fallback() external payable {}
}
