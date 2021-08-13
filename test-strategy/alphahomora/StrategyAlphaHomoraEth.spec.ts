import { expect } from 'chai';
import { ethers, network } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseEther, parseUnits } from '@ethersproject/units';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

import { ERC20 } from '../../typechain/ERC20.d';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyAlphaHomoraEth__factory } from '../../typechain/factories/StrategyAlphaHomoraEth__factory';
import { StrategyAlphaHomoraEth } from '../../typechain/StrategyAlphaHomoraEth';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';


describe('StrategyAlphaHomoraEth', function () {
  async function deploy() {
    const deployerSigner = await getDeployerSigner();

    let strategy: StrategyAlphaHomoraEth;
    const deployedAddress = process.env.STRATEGY_ALPHAHOMORA_ETH;
    if (deployedAddress) {
      strategy = StrategyAlphaHomoraEth__factory.connect(deployedAddress, deployerSigner);
    } else {
      const StrategyAlphaHomoraEthFactory = (await ethers.getContractFactory(
        'StrategyAlphaHomoraEth'
      )) as StrategyAlphaHomoraEth__factory;
      strategy = await StrategyAlphaHomoraEthFactory
        .connect(deployerSigner)
        .deploy(
          process.env.ALPHAHOMORA_IBETH as string,
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
    await expect(strategy.aggregateOrders(parseEther('5'), parseEther('0'), parseEther('4'), parseEther('0')))
      .to.emit(strategy, 'Buy')

    const price1 = await strategy.callStatic.syncPrice();
    console.log('price1:', price1.toString());
    expect(price1).to.lte(parseEther('1'));

    console.log('===== Sell 2 =====');
    await expect(strategy.aggregateOrders(parseEther('0'), parseEther('2'), parseEther('0'), parseEther('2')))
      .to.emit(strategy, 'Sell');
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
  });
});
