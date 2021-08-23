import { getAddress } from '@ethersproject/address';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';
import { expect } from 'chai';
import * as dotenv from 'dotenv';
import { BigNumber } from 'ethers';
import { parseEther, parseUnits } from 'ethers/lib/utils';
import { ethers } from 'hardhat';
import { StrategyConvex3Pool__factory } from '../../typechain/factories/StrategyConvex3Pool__factory';
import { ERC20 } from '../../typechain/ERC20';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyConvex3Pool } from '../../typechain/StrategyConvex3Pool';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

dotenv.config();

interface IDeployInfo {
  strategy: StrategyConvex3Pool;
  supplyTokenContract: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deploy(
  deployedAddress: string | undefined,
  supplyToken: string,
  supplyTokenDecimal: number,
  supplyTokenIndex: number,
  poolAddress: string,
  lpTokenAddress: string,
  convexAddress: string,
  convexRewardsAddress: string,
  convexPoolId: number
): Promise<IDeployInfo> {
  const deployerSigner = await getDeployerSigner();

  let strategy: StrategyConvex3Pool;

  // connect to strategy contract, deploy the contract if it's not deployed yet
  if (deployedAddress) {
    strategy = StrategyConvex3Pool__factory.connect(deployedAddress, deployerSigner);
  } else {
    const factory = (await ethers.getContractFactory('StrategyConvex3Pool')) as StrategyConvex3Pool__factory;
    console.log(
      'Deploying strategy contract\n',
      deployerSigner.address + '\n',
      lpTokenAddress + '\n',
      (process.env.CURVE_3POOL_3CRV as string) + '\n',
      supplyTokenIndex + '\n',
      poolAddress + '\n'
    );
    strategy = await factory
      .connect(deployerSigner)
      .deploy(
        deployerSigner.address,
        supplyToken,
        supplyTokenDecimal,
        supplyTokenIndex,
        poolAddress,
        lpTokenAddress,
        convexAddress,
        convexRewardsAddress,
        convexPoolId
      );
    await strategy.deployed();
    console.log('strategy address', strategy.address);
  }

  const supplyTokenContract = ERC20__factory.connect(supplyToken, deployerSigner);

  return { strategy, supplyTokenContract, deployerSigner };
}

const getUnitParser = (decimals: number) => {
  return (value: string) => {
    return parseUnits(value, decimals);
  };
};

export async function testStrategyConvex3Pool(
  context: Mocha.Context,
  deployedAddress: string | undefined,
  supplyToken: string,
  supplyTokenDecimal: number,
  index: number,
  supplyTokenFunder: string
): Promise<void> {
  console.log('Testing strategy with params \n', deployedAddress + '\n', index + '\n', supplyTokenFunder + '\n');

  context.timeout(300000);
  const { strategy, supplyTokenContract, deployerSigner } = await deploy(
    deployedAddress,
    supplyToken,
    supplyTokenDecimal,
    index,
    process.env.CURVE_3POOL as string,
    process.env.CURVE_3POOL_3CRV as string,
    process.env.CONVEX_BOOSTER as string,
    process.env.CONVEX_REWARDS as string,
    9
  );

  const p = getUnitParser(supplyTokenDecimal);

  console.log('\n>>> ensuring contract deployment');
  const assetAddress = getAddress(await strategy.getAssetAddress());
  console.log('----- asset address', assetAddress);
  expect(assetAddress).to.equal(getAddress(supplyToken));
  const price = await strategy.callStatic.syncPrice();
  console.log('----- price after contract deployment', price.toString());
  expect(price).to.equal(parseEther('1'));

  console.log('\n>>> ensuring balance and approval...');
  const fundAmount = parseUnits('100', supplyTokenDecimal);
  const supplyTokenBalanceBefore = await supplyTokenContract.balanceOf(deployerSigner.address);
  console.log('----- supplyTokenBalance', supplyTokenBalanceBefore.toString());
  await ensureBalanceAndApproval(
    supplyTokenContract,
    '',
    fundAmount,
    deployerSigner,
    strategy.address,
    supplyTokenFunder
  );
  const supplyTokenBalance = await supplyTokenContract.balanceOf(deployerSigner.address);
  console.log('----- supplyTokenBalance', supplyTokenBalance.toString());

  console.log('\n>>> set slippage to 6%');
  await strategy.setSlippage(600);
  const newSlippage = await strategy.slippage();
  console.log('----- slippage', newSlippage.toString());

  console.log('\n>>> aggregateOrders #1 -> buy 100 sell 0');
  const aggregateOrder1Gas = await strategy.estimateGas.aggregateOrders(p('100'), p('0'), p('90'), p('0'));
  await expect(await strategy.aggregateOrders(p('100'), p('0'), p('90'), p('0')))
    .to.emit(strategy, 'Buy')
    .to.not.emit(strategy, 'Sell');
  const shares2 = await strategy.shares();
  const price2 = await strategy.callStatic.syncPrice();
  const assetAmount2 = price2.mul(shares2).div(BigNumber.from(10).pow(18));
  console.log('----- estimated gas =', aggregateOrder1Gas.toString());
  console.log('----- shares =', shares2.toString());
  console.log('----- price =', price2.toString());
  console.log('----- assetAmount =', assetAmount2.toString());
  expect(assetAmount2).to.gte(p('95')).to.lt(p('105'));
  expect(aggregateOrder1Gas).to.lt(10000000);

  console.log('\n>>> aggregateOrders #2 -> buy 0 sell 50');
  const aggregateOrder2Gas = await strategy.estimateGas.aggregateOrders(p('0'), p('50'), p('0'), p('45'));
  await expect(strategy.aggregateOrders(p('0'), p('50'), p('0'), p('45')))
    .to.emit(strategy, 'Sell')
    .to.not.emit(strategy, 'Buy');
  const shares3 = await strategy.shares();
  const price3 = await strategy.callStatic.syncPrice();
  const assetAmount3 = price3.mul(shares3).div(BigNumber.from(10).pow(18));
  console.log('----- estimated gas =', aggregateOrder2Gas.toString());
  console.log('----- shares =', shares3.toString());
  console.log('----- price =', price3.toString());
  console.log('----- assetAmount =', assetAmount3.toString());
  expect(assetAmount3).to.gte(p('45')).to.lt(p('65'));
  expect(aggregateOrder2Gas).to.lt(10000000);

  console.log('\n>>> aggregateOrders #3 -> buy 40 sell 10');
  const aggregateOrder3Gas = await strategy.estimateGas.aggregateOrders(p('40'), p('10'), p('35'), p('8'));
  await expect(strategy.aggregateOrders(p('40'), p('10'), p('35'), p('8')))
    .to.emit(strategy, 'Buy')
    .to.emit(strategy, 'Sell');
  const shares4 = await strategy.shares();
  const price4 = await strategy.callStatic.syncPrice();
  const assetAmount4 = price4.mul(shares4).div(BigNumber.from(10).pow(18));
  console.log('----- estimated gas =', aggregateOrder3Gas.toString());
  console.log('----- shares =', shares4.toString());
  console.log('----- price =', price4.toString());
  console.log('----- assetAmount =', assetAmount4.toString());
  expect(assetAmount4).to.gte(p('75')).to.lt(p('85'));
  expect(aggregateOrder3Gas).to.lt(10000000);

  console.log('\n>>> aggregateOrders #4 -> buy 10 sell 100 (oversell)');
  await expect(strategy.aggregateOrders(p('10'), p('100'), p('8'), p('95'))).to.revertedWith(
    'not enough shares to sell'
  );
  console.log('----- successfully reverted');

  console.log('\n>>> aggregateOrders #4 -> buy 10 minBuy 11 (fail min buy)');
  await expect(strategy.aggregateOrders(p('10'), p('0'), p('11'), p('0'))).to.revertedWith(
    'failed min shares from buy'
  );
  console.log('----- successfully reverted');

  console.log('\n>>> aggregateOrders #4 -> sell 10 minSell 11 (fail min sell)');
  await expect(strategy.aggregateOrders(p('0'), p('10'), p('0'), p('11'))).to.revertedWith(
    'failed min amount from sell'
  );
  console.log('----- successfully reverted');

  // estimate gas for harvest
  const harvestGas = await strategy.estimateGas.harvest();
  console.log('\n>>> estimated harvest gas =', harvestGas.toString());
  if (harvestGas.gt(2000000)) {
    console.log('Harvest gas is greater than 2mil!');
  }

  console.log('\n>>> harvest #1 after 30 days');
  await ethers.provider.send('evm_increaseTime', [60 * 60 * 24 * 30]);
  const harvestTx = await strategy.harvest({ gasLimit: 2000000 });
  const receipt = await harvestTx.wait();
  console.log('---- gas used =', receipt.gasUsed.toString());
  const price5 = await strategy.callStatic.syncPrice();
  const shares5 = await strategy.shares();
  const assetAmount5 = price5.mul(shares5).div(BigNumber.from(10).pow(18));
  console.log('---- shares =', shares5.toString());
  console.log('---- price =', price5.toString());
  console.log('---- assetAmount =', assetAmount5.toString());
  expect(shares5).to.eq(shares5);
  expect(assetAmount5).to.gte(assetAmount5);

  console.log('\n>>> harvest #2 after another 2 days');
  await ethers.provider.send('evm_increaseTime', [60 * 60 * 24 * 2]);
  const harvestTx2 = await strategy.harvest({ gasLimit: 2000000 });
  const receipt2 = await harvestTx2.wait();
  console.log('---- gas used =', receipt2.gasUsed.toString());
  const price6 = await strategy.callStatic.syncPrice();
  const shares6 = await strategy.shares();
  const assetAmount6 = price6.mul(shares6).div(BigNumber.from(10).pow(18));
  console.log('---- shares =', shares6.toString());
  console.log('---- price =', price6.toString());
  console.log('---- assetAmount =', assetAmount6.toString());
  expect(shares6).to.eq(shares6);
  expect(assetAmount6).to.gte(assetAmount6);
}
