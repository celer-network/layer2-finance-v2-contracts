import { getAddress } from '@ethersproject/address';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';
import { expect } from 'chai';
import * as dotenv from 'dotenv';
import { BigNumber } from 'ethers';
import { parseEther, parseUnits } from 'ethers/lib/utils';
import { ethers } from 'hardhat';
import { ERC20 } from '../../typechain/ERC20';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyCurveEth__factory } from '../../typechain/factories/StrategyCurveEth__factory';
import { StrategyCurveEth } from '../../typechain/StrategyCurveEth';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

dotenv.config();

const ETH_DECIMALS = 18;

interface DeployStrategyCurveEthInfo {
  strategy: StrategyCurveEth;
  weth: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deployStrategyCurveEth(
  deployedAddress: string | undefined,
  ethIndexInPool: number,
  poolAddress: string,
  lpTokenAddress: string,
  gaugeAddress: string
): Promise<DeployStrategyCurveEthInfo> {
  const deployerSigner = await getDeployerSigner();

  let strategy: StrategyCurveEth;

  // connect to strategy contract, deploy the contract if it's not deployed yet
  if (deployedAddress) {
    strategy = StrategyCurveEth__factory.connect(deployedAddress, deployerSigner);
  } else {
    const strategyCurveEthFactory = (await ethers.getContractFactory('StrategyCurveEth')) as StrategyCurveEth__factory;
    console.log(
      'Deploying strategy contract',
      deployerSigner.address,
      lpTokenAddress,
      process.env.WETH as string,
      ethIndexInPool,
      poolAddress,
      gaugeAddress,
      process.env.CURVE_MINTR as string,
      process.env.CURVE_CRV as string,
      process.env.UNISWAP_ROUTER as string
    );
    strategy = await strategyCurveEthFactory
      .connect(deployerSigner)
      .deploy(
        deployerSigner.address,
        lpTokenAddress,
        process.env.WETH as string,
        ethIndexInPool,
        poolAddress,
        gaugeAddress,
        process.env.CURVE_MINTR as string,
        process.env.CURVE_CRV as string,
        process.env.UNISWAP_ROUTER as string
      );
    await strategy.deployed();
    console.log('strategy address', strategy.address);
  }

  const weth = ERC20__factory.connect(process.env.WETH as string, deployerSigner);

  return { strategy, weth, deployerSigner };
}

const p = parseEther;

export async function testStrategyCurveEth(
  context: Mocha.Context,
  deployedAddress: string | undefined,
  ethIndexInPool: number,
  poolAddress: string,
  lpTokenAddress: string,
  gaugeAddress: string,
  supplyTokenFunder: string
): Promise<void> {
  console.log(
    'Testing strategy with params',
    deployedAddress,
    ethIndexInPool,
    poolAddress,
    lpTokenAddress,
    gaugeAddress,
    supplyTokenFunder
  );

  context.timeout(300000);
  const { strategy, weth, deployerSigner } = await deployStrategyCurveEth(
    deployedAddress,
    ethIndexInPool,
    poolAddress,
    lpTokenAddress,
    gaugeAddress
  );

  console.log('\n>>> ensuring contract deployment');
  const assetAddress = getAddress(await strategy.getAssetAddress());
  console.log('----- asset address', assetAddress);
  expect(assetAddress).to.equal(getAddress(weth.address));
  const price = await strategy.callStatic.syncPrice();
  console.log('----- price after contract deployment', price.toString());
  expect(price).to.equal(p('1'));

  console.log('\n>>> ensuring balance and approval...');
  const balance = parseUnits('10', ETH_DECIMALS);
  await ensureBalanceAndApproval(weth, 'WETH', balance, deployerSigner, strategy.address, supplyTokenFunder);

  console.log('\n>>> set slippage to 10%');
  await strategy.setSlippage(1000);
  const newSlippage = await strategy.slippage();
  console.log('----- slippage', newSlippage.toString());

  console.log('\n>>> aggregateOrders #1 -> buy 5 sell 0');
  const aggregateOrder1Gas = await strategy.estimateGas.aggregateOrders(p('5'), p('0'), p('4'), p('0'));
  await expect(await strategy.aggregateOrders(p('5'), p('0'), p('4'), p('0')))
    .to.emit(strategy, 'Buy')
    .to.not.emit(strategy, 'Sell');
  const shares2 = await strategy.shares();
  const price2 = await strategy.callStatic.syncPrice();
  const assetAmount2 = price2.mul(shares2).div(BigNumber.from(10).pow(18));
  console.log('----- estimated gas =', aggregateOrder1Gas.toString());
  console.log('----- shares =', shares2.toString());
  console.log('----- price =', price2.toString());
  console.log('----- assetAmount =', assetAmount2.toString());
  expect(assetAmount2).to.gte(p('4.5')).to.lt(p('5.5'));
  expect(aggregateOrder1Gas).to.lt(2000000);

  console.log('\n>>> aggregateOrders #2 -> buy 0 sell 3');
  const aggregateOrder2Gas = await strategy.estimateGas.aggregateOrders(p('0'), p('3'), p('0'), p('2'));
  await expect(strategy.aggregateOrders(p('0'), p('3'), p('0'), p('2')))
    .to.emit(strategy, 'Sell')
    .to.not.emit(strategy, 'Buy');
  const shares3 = await strategy.shares();
  const price3 = await strategy.callStatic.syncPrice();
  const assetAmount3 = price3.mul(shares3).div(BigNumber.from(10).pow(18));
  console.log('----- estimated gas =', aggregateOrder2Gas.toString());
  console.log('----- shares =', shares3.toString());
  console.log('----- price =', price3.toString());
  console.log('----- assetAmount =', assetAmount3.toString());
  expect(assetAmount3).to.gte(p('1.5')).to.lt(p('2.5'));
  expect(aggregateOrder2Gas).to.lt(2000000);

  console.log('\n>>> aggregateOrders #3 -> buy 4 sell 1');
  const aggregateOrder3Gas = await strategy.estimateGas.aggregateOrders(p('4'), p('1'), p('3'), p('0.5'));
  await expect(strategy.aggregateOrders(p('4'), p('1'), p('3'), p('0.5')))
    .to.emit(strategy, 'Buy')
    .to.emit(strategy, 'Sell');
  const shares4 = await strategy.shares();
  const price4 = await strategy.callStatic.syncPrice();
  const assetAmount4 = price4.mul(shares4).div(BigNumber.from(10).pow(18));
  console.log('----- estimated gas =', aggregateOrder3Gas.toString());
  console.log('----- shares =', shares4.toString());
  console.log('----- price =', price4.toString());
  console.log('----- assetAmount =', assetAmount4.toString());
  expect(assetAmount4).to.gte(p('4.5')).to.lt(p('5.5'));
  expect(aggregateOrder3Gas).to.lt(2000000);

  console.log('\n>>> aggregateOrders #4 -> buy 1 sell 8 (not enough shares)');
  await expect(strategy.aggregateOrders(p('1'), p('8'), p('0.5'), p('7'))).to.revertedWith('not enough shares to sell');

  console.log('\n>>> aggregateOrders #4 -> buy 1 minBuy 1.1 (fail min buy)');
  await expect(strategy.aggregateOrders(p('1'), p('0'), p('1.1'), p('0'))).to.revertedWith(
    'failed min shares from buy'
  );
  console.log('----- successfully reverted');

  console.log('\n>>> aggregateOrders #4 -> sell 1 minSell 1.1 (fail min sell)');
  await expect(strategy.aggregateOrders(p('0'), p('1'), p('0'), p('1.1'))).to.revertedWith(
    'failed min amount from sell'
  );
  console.log('----- successfully reverted');

  console.log('\n>>> harvest #1 after 1 days');
  await ethers.provider.send('evm_increaseTime', [60 * 60 * 24]);
  const harvestGas = await strategy.estimateGas.harvest();
  console.log('\n>>> estimated harvest gas =', harvestGas.toString());
  if (harvestGas.gt(2000000)) {
    console.log('Harvest gas is greater than 2mil!');
  }
  const harvestTx = await strategy.harvest({ gasLimit: 2000000 });
  const receipt = await harvestTx.wait();
  console.log('---- gas used =', receipt.gasUsed.toString());
  const price5 = await strategy.callStatic.syncPrice();
  const shares5 = await strategy.shares();
  const assetAmount5 = price5.mul(shares4).div(BigNumber.from(10).pow(18));
  console.log('---- shares =', shares5.toString());
  console.log('---- price =', price5.toString());
  console.log('---- assetAmount =', assetAmount5.toString());
  expect(shares5).to.eq(shares4);
  expect(assetAmount5).to.gte(assetAmount4);

  console.log('\n>>> harvest #2 after another 1 days');
  await ethers.provider.send('evm_increaseTime', [60 * 60 * 24]);
  const harvestTx2 = await strategy.harvest({ gasLimit: 2000000 });
  const receipt2 = await harvestTx2.wait();
  console.log('---- gas used =', receipt2.gasUsed.toString());
  const price6 = await strategy.callStatic.syncPrice();
  const shares6 = await strategy.shares();
  const assetAmount6 = price6.mul(shares4).div(BigNumber.from(10).pow(18));
  console.log('---- shares =', shares6.toString());
  console.log('---- price =', price6.toString());
  console.log('---- assetAmount =', assetAmount6.toString());
  expect(shares6).to.eq(shares4);
  expect(assetAmount6).to.gte(assetAmount4);
}
