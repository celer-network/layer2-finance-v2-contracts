import { expect } from 'chai';
import { ethers } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseUnits } from '@ethersproject/units';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

import { ERC20 } from '../../typechain/ERC20.d';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyAlphaHomoraErc20__factory } from '../../typechain/factories/StrategyAlphaHomoraErc20__factory';
import { StrategyAlphaHomoraErc20 } from '../../typechain/StrategyAlphaHomoraErc20';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

interface DeployStrategyAlphaHomoraErc20Info {
  strategy: StrategyAlphaHomoraErc20;
  supplyToken: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deployStrategyAlphaHomoraErc20(
  deployedAddress: string | undefined,
  supplyTokenAddress: string,
  ibTokenAddress: string
): Promise<DeployStrategyAlphaHomoraErc20Info> {
  const deployerSigner = await getDeployerSigner();
  let strategy: StrategyAlphaHomoraErc20;
  if (deployedAddress) {
    strategy = StrategyAlphaHomoraErc20__factory.connect(deployedAddress, deployerSigner);
  } else {
    const StrategyAlphaHomoraErc20Factory = (await ethers.getContractFactory(
      'StrategyAlphaHomoraErc20'
    )) as StrategyAlphaHomoraErc20__factory;
    strategy = await StrategyAlphaHomoraErc20Factory.connect(deployerSigner).deploy(
      ibTokenAddress,
      supplyTokenAddress,
      deployerSigner.address
    );
    await strategy.deployed();
  }

  const supplyToken = ERC20__factory.connect(supplyTokenAddress, deployerSigner);

  return { strategy, supplyToken, deployerSigner };
}

export async function testStrategyAlphaHomoraErc20(
  context: Mocha.Context,
  deployedAddress: string | undefined,
  supplyTokenAddress: string,
  ibTokenAddress: string,
  supplyTokenFunder: string,
  supplyTokenDecimals: number,
  supplyTokenSymbol: string
): Promise<void> {
  context.timeout(300000);

  const { strategy, supplyToken, deployerSigner } = await deployStrategyAlphaHomoraErc20(
    deployedAddress,
    supplyTokenAddress,
    ibTokenAddress
  );

  expect(getAddress(await strategy.getAssetAddress())).to.equal(getAddress(supplyToken.address));

  const displayCommitAmount = '100';
  const commitAmount = parseUnits(displayCommitAmount, supplyTokenDecimals);
  await ensureBalanceAndApproval(
    supplyToken,
    supplyTokenSymbol,
    commitAmount,
    deployerSigner,
    strategy.address,
    supplyTokenFunder
  );
  console.log('===== Buy 5 =====');
  let receipt = await (
    await strategy.aggregateOrders(
      parseUnits('5', supplyTokenDecimals),
      parseUnits('0'),
      parseUnits('4.99', supplyTokenDecimals),
      parseUnits('0')
    )
  ).wait();
  receipt.events?.forEach((evt) => {
    if (evt.event == 'Buy') {
      console.log('buy  amount:', evt.args![0].toString(), 'sharesFromBuy:', evt.args![1].toString());
    }
  });
  console.log('price:', (await strategy.getPrice()).toString());

  console.log('===== Sell 2 =====');
  receipt = await (
    await strategy.aggregateOrders(
      parseUnits('0'),
      parseUnits('2', supplyTokenDecimals),
      parseUnits('0'),
      parseUnits('1.99', supplyTokenDecimals)
    )
  ).wait();
  receipt.events?.forEach((evt) => {
    if (evt.event == 'Sell') {
      console.log('sell shares:', evt.args![0].toString(), 'amountFromSell:', evt.args![1].toString());
    }
  });
  console.log('price:', (await strategy.getPrice()).toString());

  console.log('===== Buy 1, Sell 2 =====');
  receipt = await (
    await strategy.aggregateOrders(
      parseUnits('1', supplyTokenDecimals),
      parseUnits('2', supplyTokenDecimals),
      parseUnits('1', supplyTokenDecimals),
      parseUnits('1.99', supplyTokenDecimals)
    )
  ).wait();
  receipt.events?.forEach((evt) => {
    if (evt.event == 'Buy') {
      console.log('buy  amount:', evt.args![0].toString(), 'sharesFromBuy:', evt.args![1].toString());
    }
    if (evt.event == 'Sell') {
      console.log('sell shares:', evt.args![0].toString(), 'amountFromSell:', evt.args![1].toString());
    }
  });
  console.log('price:', (await strategy.getPrice()).toString());
}
