import { expect } from 'chai';
import { ethers, network } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseEther } from '@ethersproject/units';

import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyCompoundEthLendingPool__factory } from '../../typechain/factories/StrategyCompoundEthLendingPool__factory';
import { StrategyCompoundEthLendingPool } from '../../typechain/StrategyCompoundEthLendingPool.d';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

describe('StrategyCompoundETH', function () {
  async function deploy() {
    const deployerSigner = await getDeployerSigner();

    let strategy: StrategyCompoundEthLendingPool;
    const deployedAddress = process.env.STRATEGY_COMPOUND_ETH;
    if (deployedAddress) {
      strategy = StrategyCompoundEthLendingPool__factory.connect(deployedAddress, deployerSigner);
    } else {
      const strategyCompoundEthLendingPoolFactory = (await ethers.getContractFactory(
        'StrategyCompoundEthLendingPool'
      )) as StrategyCompoundEthLendingPool__factory;
      strategy = await strategyCompoundEthLendingPoolFactory
        .connect(deployerSigner)
        .deploy(
          process.env.COMPOUND_CETH as string,
          process.env.COMPOUND_COMPTROLLER as string,
          process.env.COMPOUND_COMP as string,
          process.env.UNISWAP_ROUTER as string,
          process.env.WETH as string,
          deployerSigner.address
        );
      await strategy.deployed();
    }

    const weth = ERC20__factory.connect(process.env.WETH as string, deployerSigner);

    return { strategy, weth, deployerSigner };
  }

  it('should buy, sell and optionally harvest', async function () {
    this.timeout(300000);

    const { strategy, weth, deployerSigner } = await deploy();

    expect(getAddress(await strategy.getAssetAddress())).to.equal(getAddress(weth.address));

    const commitAmount = parseEther('10');
    await ensureBalanceAndApproval(
      weth,
      'WETH',
      commitAmount,
      deployerSigner,
      strategy.address,
      process.env.WETH_FUNDER as string
    );

    console.log('===== Buy 5 =====');
    await expect(strategy.aggregateOrders(parseEther('5'), parseEther('0'), parseEther('5'), parseEther('0')))
      .to.emit(strategy, 'Buy')
      .withArgs(parseEther('5'), parseEther('5'));

    expect(await strategy.shares()).to.equal(parseEther('5'));
    const price1 = await strategy.callStatic.syncPrice();
    console.log('price1:', price1.toString());
    expect(price1).to.lte(parseEther('1'));

    console.log('===== Sell 2 =====');
    await expect(strategy.aggregateOrders(parseEther('0'), parseEther('2'), parseEther('0'), parseEther('2')))
      .to.emit(strategy, 'Sell');
    expect(await strategy.shares()).to.equal(parseEther('3'));
    const price2 = await strategy.callStatic.syncPrice();
    console.log('price2:', price2.toString());
    expect(price2).to.gte(price1);

    console.log('===== Buy 1, Sell 2 =====');
    await expect(strategy.aggregateOrders(parseEther('1'), parseEther('2'), parseEther('0.5'), parseEther('2')))
      .to.emit(strategy, 'Buy')
      .to.emit(strategy, 'Sell');
    expect(await strategy.shares()).to.lte(parseEther('2'));
    const price3 = await strategy.callStatic.syncPrice();
    console.log('price3:', price3.toString());
    expect(price3).to.gte(price2);

    console.log('===== harvest, and price should be updated =====');
    try {
      // Send some COMP to the strategy
      const comp = ERC20__factory.connect(process.env.COMPOUND_COMP as string, deployerSigner);
      await network.provider.request({
        method: 'hardhat_impersonateAccount',
        params: [process.env.COMPOUND_COMP_FUNDER]
      });
      await (
        await comp
          .connect(await ethers.getSigner(process.env.COMPOUND_COMP_FUNDER as string))
          .transfer(strategy.address, parseEther('0.01'))
      ).wait();
      console.log('===== Sent COMP to the strategy, harvesting =====');
      const harvestGas = await strategy.estimateGas.harvest();
      if (harvestGas.lte(2000000)) {
        const harvestTx = await strategy.harvest({ gasLimit: 2000000 });
        const receipt = await harvestTx.wait();
        console.log('Harvest gas used:', receipt.gasUsed.toString());
        const price4 =  await strategy.callStatic.syncPrice();
        console.log(
          `price4:`, price4.toString()
        );
        expect(price4).to.gte(price3);
      }
    } catch (e) {
      console.log('Cannot harvest:', e);
    }
  });
});
