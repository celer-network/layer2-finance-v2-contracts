import { expect } from 'chai';
import { ethers } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseUnits, parseEther } from '@ethersproject/units';

import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
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
          process.env.WETH as string,
          process.env.UNISWAP_ROUTER as string,
          process.env.LIQUITY_LQTY as string,
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
    this.timeout(600000);

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

    await expect(strategy.aggregateOrders(parseEther('5'), parseEther('0'), parseEther('5'), parseEther('0')))
      .to.emit(strategy, 'Buy')
      .withArgs(parseEther('5'), parseEther('5'));

    expect(await strategy.shares()).to.equal(parseEther('5'));
    expect(await strategy.callStatic.syncPrice()).to.equal(parseEther('1'));
  });
});
