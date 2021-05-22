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
    const erc20 = await testERC20Factory.deploy();
    await erc20.deployed();

    const strategyDummyFactory = (await ethers.getContractFactory('StrategyDummy')) as StrategyDummy__factory;
    const strategyDummy = await strategyDummyFactory.deploy(
      admin.address,
      erc20.address,
      admin.address,
      parseEther('1')
    );
    await strategyDummy.deployed();

    await erc20.approve(strategyDummy.address, parseEther('20'));
    return { strategyDummy, erc20 };
  }

  it('should return asset address', async function () {
    const { strategyDummy, erc20 } = await loadFixture(fixture);
    expect(await strategyDummy.getAssetAddress()).to.equal(erc20.address);
  });

  it('should aggregate orders correctly', async function () {
    const { strategyDummy } = await loadFixture(fixture);
    await expect(strategyDummy.aggregateOrders(parseEther('5'), parseEther('5'), parseEther('0'), parseEther('0')))
      .to.emit(strategyDummy, 'Buy')
      .withArgs(parseEther('5'), parseEther('5'));

    expect(await strategyDummy.assetAmount()).to.equal(parseEther('5'));
    expect(await strategyDummy.shares()).to.equal(parseEther('5'));
    expect(await strategyDummy.syncPrice()).to.equal(parseEther('1'));

    await expect(strategyDummy.aggregateOrders(parseEther('0'), parseEther('0'), parseEther('2'), parseEther('2')))
      .to.emit(strategyDummy, 'Sell')
      .withArgs(parseEther('2'), parseEther('2'));

    expect(await strategyDummy.assetAmount()).to.equal(parseEther('3'));
    expect(await strategyDummy.shares()).to.equal(parseEther('3'));
    expect(await strategyDummy.syncPrice()).to.equal(parseEther('1'));

    await expect(strategyDummy.aggregateOrders(parseEther('1'), parseEther('1'), parseEther('2'), parseEther('2')))
      .to.emit(strategyDummy, 'Buy')
      .withArgs(parseEther('1'), parseEther('1'))
      .to.emit(strategyDummy, 'Sell')
      .withArgs(parseEther('2'), parseEther('2'));
    expect(await strategyDummy.assetAmount()).to.equal(parseEther('2'));
    expect(await strategyDummy.shares()).to.equal(parseEther('2'));
    expect(await strategyDummy.syncPrice()).to.equal(parseEther('1'));
  });

  it('should fail if min share/asset amount requirement not met', async function () {
    const { strategyDummy } = await loadFixture(fixture);
    await expect(
      strategyDummy.aggregateOrders(parseEther('5'), parseEther('6'), parseEther('0'), parseEther('0'))
    ).to.be.revertedWith('failed min shares from buy');

    await strategyDummy.aggregateOrders(parseEther('5'), parseEther('5'), parseEther('0'), parseEther('0'));
    await expect(
      strategyDummy.aggregateOrders(parseEther('0'), parseEther('0'), parseEther('3'), parseEther('4'))
    ).to.be.revertedWith('failed min amount from sell');
  });

  it('should calculate price correctly', async function () {
    const { strategyDummy } = await loadFixture(fixture);
    await strategyDummy.aggregateOrders(parseEther('2'), parseEther('2'), parseEther('0'), parseEther('0'));
    expect(await strategyDummy.assetAmount()).to.equal(parseEther('2'));
    expect(await strategyDummy.shares()).to.equal(parseEther('2'));
    expect(await strategyDummy.syncPrice()).to.equal(parseEther('1'));

    await strategyDummy.harvest();
    expect(await strategyDummy.assetAmount()).to.equal(parseEther('3'));
    expect(await strategyDummy.shares()).to.equal(parseEther('2'));
    expect(await strategyDummy.syncPrice()).to.equal(parseEther('1.5'));

    await expect(strategyDummy.aggregateOrders(parseEther('6'), parseEther('4'), parseEther('1.5'), parseEther('2')))
      .to.emit(strategyDummy, 'Buy')
      .withArgs(parseEther('6'), parseEther('4'))
      .to.emit(strategyDummy, 'Sell')
      .withArgs(parseEther('1.5'), parseEther('2.25'));

    expect(await strategyDummy.assetAmount()).to.equal(parseEther('6.75'));
    expect(await strategyDummy.shares()).to.equal(parseEther('4.5'));
    expect(await strategyDummy.syncPrice()).to.equal(parseEther('1.5'));

    await strategyDummy.decreaseBalance(parseEther('1.35'));
    expect(await strategyDummy.assetAmount()).to.equal(parseEther('5.4'));
    expect(await strategyDummy.shares()).to.equal(parseEther('4.5'));
    expect(await strategyDummy.syncPrice()).to.equal(parseEther('1.2'));

    await expect(strategyDummy.aggregateOrders(parseEther('2.4'), parseEther('2'), parseEther('1'), parseEther('1.2')))
      .to.emit(strategyDummy, 'Buy')
      .withArgs(parseEther('2.4'), parseEther('2'))
      .to.emit(strategyDummy, 'Sell')
      .withArgs(parseEther('1'), parseEther('1.2'));
    expect(await strategyDummy.assetAmount()).to.equal(parseEther('6.6'));
    expect(await strategyDummy.shares()).to.equal(parseEther('5.5'));
    expect(await strategyDummy.syncPrice()).to.equal(parseEther('1.2'));
  });
});
