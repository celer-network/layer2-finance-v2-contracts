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

import * as dotenv from 'dotenv';

dotenv.config();

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
    const supplyTokenDecimals = 18;
    console.log('===== Buy 5 =====');
    let receipt = await (await strategy.aggregateOrders(parseUnits('5', supplyTokenDecimals), parseUnits('0'), parseUnits('4.99', supplyTokenDecimals), parseUnits('0'))).wait();
    receipt.events?.forEach((evt)=>{
    if (evt.event=='Buy') {
        console.log("buy  amount:", evt.args![0].toString(), "sharesFromBuy:", evt.args![1].toString());
      }
    });
    console.log("price:", (await strategy.callStatic.syncPrice()).toString());

    console.log('===== Sell 2 =====');
    receipt = await (await strategy.aggregateOrders(parseUnits('0'), parseUnits('2', supplyTokenDecimals), parseUnits('0'), parseUnits('1.99', supplyTokenDecimals))).wait();
    receipt.events?.forEach((evt)=>{
    if (evt.event=='Sell') {
        console.log("sell shares:", evt.args![0].toString(), "amountFromSell:", evt.args![1].toString());
      }
    });
    console.log("price:", (await strategy.callStatic.syncPrice()).toString());

    console.log('===== Buy 1, Sell 2 =====');
    receipt = await (await strategy.aggregateOrders(parseUnits('1', supplyTokenDecimals), parseUnits('2', supplyTokenDecimals), parseUnits('1', supplyTokenDecimals), parseUnits('1.99', supplyTokenDecimals))).wait();
    receipt.events?.forEach((evt)=>{
      if (evt.event=='Buy') {
        console.log("buy  amount:", evt.args![0].toString(), "sharesFromBuy:", evt.args![1].toString());
      }
      if (evt.event=='Sell') {
          console.log("sell shares:", evt.args![0].toString(), "amountFromSell:", evt.args![1].toString());
        }
      });
      console.log("price:", (await strategy.callStatic.syncPrice()).toString());
  });
});
