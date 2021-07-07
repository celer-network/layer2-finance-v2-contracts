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
    strategy = await strategyCurveEthFactory
      .connect(deployerSigner)
      .deploy(
        deployerSigner.address,
        ethIndexInPool,
        poolAddress,
        lpTokenAddress,
        gaugeAddress,
        process.env.CURVE_MINTR as string,
        process.env.CURVE_CRV as string,
        process.env.WETH as string,
        process.env.UNISWAP_ROUTER as string
      );
    await strategy.deployed();
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
  context.timeout(300000);
  const { strategy, weth, deployerSigner } = await deployStrategyCurveEth(
    deployedAddress,
    ethIndexInPool,
    poolAddress,
    lpTokenAddress,
    gaugeAddress
  );

  console.log('should set asset address to weth address');
  const assetAddress = getAddress(await strategy.getAssetAddress());
  console.log('>>> asset address', assetAddress);
  expect(assetAddress).to.equal(getAddress(weth.address));

  console.log('should have 1e18 price when contract tracks zero shares and asset amount');
  const price = await strategy.syncPrice();
  console.log('>>> Price after contract deployment', price);
  expect(price).to.equal(p('1'));

  console.log('>>> ensuring balance and approval...');
  const balance = parseUnits('10', ETH_DECIMALS);
  await ensureBalanceAndApproval(weth, 'WETH', balance, deployerSigner, strategy.address, supplyTokenFunder);

  console.log('>>> aggregateOrders #1 -> buy 1 sell 0');
  await expect(strategy.aggregateOrders(p('1'), p('0.8'), p('0'), p('0')))
    .to.emit(strategy, 'Buy')
    .withArgs(p('1'), p('0'));
  const assetAmount2 = await strategy.assetAmount();
  expect(assetAmount2).to.equal(p('1'));
  const price2 = await strategy.syncPrice();
  console.log('>>> Price after aggregateOrders #1', price.toString());
  expect(price2).to.equal(1);

  console.log('>>> aggregateOrders #1 -> buy 0 sell 1');
  await expect(strategy.aggregateOrders(p('0'), p('0'), p('1'), p('0.8'))).to.emit(strategy, 'Sell');
}
