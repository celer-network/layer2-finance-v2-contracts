import { getAddress } from '@ethersproject/address';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';
import { expect } from 'chai';
import * as dotenv from 'dotenv';
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
  const assetAmount = await strategy.getAssetAmount();
  const shares = await strategy.shares();
  console.log('----- asset amount', assetAmount.toString(), 'shares', shares.toString());
  expect(assetAmount).to.be.equal(p('0'));
  const price = await strategy.syncPrice();
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
  await expect(await strategy.aggregateOrders(p('5'), p('0'), p('4'), p('0')))
    .to.emit(strategy, 'Buy')
    .to.not.emit(strategy, 'Sell');
  const assetAmount2 = await strategy.getAssetAmount();
  console.log('----- assetAmount =', assetAmount2.toString());
  const shares2 = await strategy.shares();
  console.log('----- shares =', shares2.toString());
  expect(assetAmount2).to.gt(p('4')).to.lt(p('5'));
  const price2 = await strategy.syncPrice();
  console.log('----- price =', price2.toString());
  expect(price2).to.equal(p('1'));
  // ----- assetAmount = 4834446375949041530
  // ----- shares = 4834446375949041530
  // ----- price = 1000000000000000000

  console.log('\n>>> aggregateOrders #2 -> buy 0 sell 3');
  await expect(strategy.aggregateOrders(p('0'), p('3'), p('0'), p('2')))
    .to.emit(strategy, 'Sell')
    .to.not.emit(strategy, 'Buy');
  const assetAmount3 = await strategy.getAssetAmount();
  console.log('----- assetAmount =', assetAmount3.toString());
  const shares3 = await strategy.shares();
  console.log('----- shares =', shares3.toString());
  expect(assetAmount3).to.gte(p('1')).to.lt(p('2'));
  const price3 = await strategy.syncPrice();
  console.log('----- price =', price3.toString());
  // ----- assetAmount = 1834446375315760224
  // ----- shares = 1732983352112039842
  // ----- price = 1058548181135187646

  console.log('\n>>> aggregateOrders #3 -> buy 4 sell 3');
  await expect(strategy.aggregateOrders(p('4'), p('3'), p('3'), p('2')))
    .to.emit(strategy, 'Buy')
    .to.emit(strategy, 'Sell');
  const assetAmount4 = await strategy.getAssetAmount();
  console.log('----- assetAmount =', assetAmount4.toString());
  const shares4 = await strategy.shares();
  console.log('----- shares =', shares4.toString());
  expect(assetAmount4).to.gte(p('2')).to.lt(p('3'));
  const price4 = await strategy.syncPrice();
  console.log('----- price =', price4.toString());
  // ----- assetAmount = 2631506827731986772
  // ----- shares = 2485958480489992235
  // ----- price = 1058548181067491675

  console.log('\n>>> aggregateOrders #4 -> buy 1 sell 4');
  await expect(strategy.aggregateOrders(p('1'), p('4'), p('0.5'), p('3'))).to.throw('not enough shares to sell');
}
