import { expect } from 'chai';
import { ethers } from 'hardhat';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { StrategyDummy__factory } from '../typechain/factories/StrategyDummy__factory';
import { TestERC20__factory } from '../typechain/factories/TestERC20__factory';
import { loadFixture } from './common';

describe('StrategyDummy', function () {
  async function fixture([admin]: Wallet[]) {
    const testERC20Factory = (await ethers.getContractFactory('TestERC20')) as TestERC20__factory;
    const testERC20 = await testERC20Factory.deploy();
    await testERC20.deployed();

    const strategyDummyFactory = (await ethers.getContractFactory('StrategyDummy')) as StrategyDummy__factory;
    const strategyDummy = await strategyDummyFactory.deploy(
      admin.address,
      testERC20.address,
      admin.address,
      parseEther('1')
    );
    await strategyDummy.deployed();
    return { strategyDummy, testERC20 };
  }

  it('should return asset address', async function () {
    const { strategyDummy, testERC20 } = await loadFixture(fixture);
    expect(await strategyDummy.getAssetAddress()).to.equal(testERC20.address);
  });

  it('should aggregate orders with net buy', async function () {
    const { strategyDummy, testERC20 } = await loadFixture(fixture);
    await testERC20.approve(strategyDummy.address, parseEther('2'));
    await expect(strategyDummy.aggregateOrders(parseEther('1'), parseEther('1'), parseEther('0'), parseEther('0')))
      .to.emit(strategyDummy, 'AggregateOrders')
      .withArgs(parseEther('1'), parseEther('0'));
  });
});
