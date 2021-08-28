import { expect } from 'chai';
import { BigNumber } from 'ethers';
import { ethers, network } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseEther, parseUnits } from '@ethersproject/units';

import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { IHintHelpers__factory } from '../../typechain/factories/IHintHelpers__factory';
import { ISortedTroves__factory } from '../../typechain/factories/ISortedTroves__factory';
import { ITroveManager__factory } from '../../typechain/factories/ITroveManager__factory';
import { StrategyLiquityPool__factory } from '../../typechain/factories/StrategyLiquityPool__factory';
import { StrategyLiquityPool } from '../../typechain/StrategyLiquityPool.d';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

describe('StrategyLiquityETH', function () {
  async function deploy() {
    const deployerSigner = await getDeployerSigner();

    let strategy: StrategyLiquityPool;
    const deployedAddress = process.env.STRATEGY_LIQUITY_ETH;
    if (deployedAddress) {
      strategy = StrategyLiquityPool__factory.connect(deployedAddress, deployerSigner);
    } else {
      const strategyLiquityPoolFactory = (await ethers.getContractFactory(
        'StrategyLiquityPool'
      )) as StrategyLiquityPool__factory;
      strategy = await strategyLiquityPoolFactory
        .connect(deployerSigner)
        .deploy(
          deployerSigner.address,
          process.env.UNISWAP_V3_ROUTER as string,
          process.env.WETH as string,
          process.env.LUSD as string,
          process.env.LQTY as string,
          [
            process.env.LIQUITY_BORROWER_OPERATIONS as string,
            process.env.LIQUITY_STABILITY_POOL as string,
            process.env.LIQUITY_HINT_HELPERS as string,
            process.env.LIQUITY_SORTED_TROVES as string,
            process.env.LIQUITY_TROVE_MANAGER as string,
            process.env.LIQUITY_PRICE_FEED as string
          ],
          parseUnits('3', 18),
          parseUnits('3.2', 18),
          parseUnits('2.5', 18),
          parseUnits('1', 18)
        );
      await strategy.deployed();
    }

    const weth = ERC20__factory.connect(process.env.WETH as string, deployerSigner);

    return { strategy, weth, deployerSigner };
  }

  it('should buy, sell and optionally harvest', async function () {
    this.timeout(3600000);

    const { strategy, weth, deployerSigner } = await deploy();

    expect(getAddress(await strategy.getAssetAddress())).to.equal(getAddress(weth.address));

    await ensureBalanceAndApproval(
      weth,
      'WETH',
      parseEther('10'),
      deployerSigner,
      strategy.address,
      process.env.WETH_FUNDER as string
    );

    console.log('===== Buy 5 =====');
    // Hardhat fork only works with a small number
    await strategy.setMaxNumHintTrials(10);
    // NOTE: The following is to set manual hints
    const troveManager = ITroveManager__factory.connect(process.env.LIQUITY_TROVE_MANAGER as string, deployerSigner);
    const lusdAmount = await troveManager.MIN_NET_DEBT();
    const ethAmount = parseEther('5');
    // Call deployed TroveManager contract to read the liquidation reserve and latest borrowing fee
    const liquidationReserve = await troveManager.LUSD_GAS_COMPENSATION();
    const expectedFee = await troveManager.getBorrowingFeeWithDecay(lusdAmount);
    // Total debt of the new trove = LUSD amount drawn, plus fee, plus the liquidation reserve
    const expectedDebt = lusdAmount.add(expectedFee).add(liquidationReserve);
    // Get the nominal NICR of the new trove
    const nicr = ethAmount.mul(parseEther('100')).div(expectedDebt);
    console.log('NICR:', nicr.toString());
    // Get an approximate address hint from the deployed HintHelper contract. Use (15 * number of troves) trials
    // to get an approx. hint that is close to the right position.
    const sortedTroves = ISortedTroves__factory.connect(process.env.LIQUITY_SORTED_TROVES as string, deployerSigner);
    const numTroves = await sortedTroves.getSize();
    let numTrials = numTroves.mul(15);
    // Hardhat fork only works with a small number
    const MAX_NUM_TRIALS = BigNumber.from('10');
    if (numTrials.gt(MAX_NUM_TRIALS)) {
      numTrials = MAX_NUM_TRIALS;
    }
    const hintHelpers = IHintHelpers__factory.connect(process.env.LIQUITY_HINT_HELPERS as string, deployerSigner);
    const { 0: approxHint } = await hintHelpers.getApproxHint(nicr, numTrials, Date.now());
    // Use the approximate hint to get the exact upper and lower hints from the deployed SortedTroves contract
    const { 0: upperHint, 1: lowerHint } = await sortedTroves.findInsertPosition(nicr, approxHint, approxHint);
    await strategy.setManualHints(true, upperHint, lowerHint);
    // More accurate hints
    await strategy.setManualHints(
      true,
      process.env.LIQUITY_MANUAL_UPPER_HINT as string,
      process.env.LIQUITY_MANUAL_LOWER_HINT as string
    );
    await expect(
      strategy.aggregateOrders(parseEther('5'), parseEther('0'), parseEther('5'), parseEther('0'), {
        gasLimit: 10000000
      })
    )
      .to.emit(strategy, 'Buy')
      .withArgs(parseEther('5'), parseEther('5'));

    expect(await strategy.shares()).to.equal(parseEther('5'));
    const price1 = await strategy.getPrice();
    expect(price1).to.equal(parseEther('1'));

    console.log('===== harvest =====');
    // Send some LQTY to the strategy
    const lqty = ERC20__factory.connect(process.env.LQTY as string, deployerSigner);
    await network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [process.env.LQTY_FUNDER]
    });
    await (
      await lqty
        .connect(await ethers.getSigner(process.env.LQTY_FUNDER as string))
        .transfer(strategy.address, parseEther('10'))
    ).wait();
    await strategy.harvest();
    const price2 = await strategy.getPrice();
    console.log('price2:', price2.toString());
  });
});
