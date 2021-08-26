import { expect } from 'chai';
import { BigNumber } from 'ethers';
import { ethers, network } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseEther, parseUnits } from '@ethersproject/units';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

import { ERC20 } from '../../typechain/ERC20';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategySushiswap__factory } from '../../typechain/factories/StrategySushiswap__factory';
import { StrategySushiswap } from '../../typechain/StrategySushiswap';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

interface DeployStrategySushiswap {
  strategy: StrategySushiswap;
  supplyToken: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deployStrategySushiswap(
  deployedAddress: string | undefined,
  supplyTokenAddress: string,
  pairTokenAddress: string,
  maxSlippage: BigNumber,
  maxOneDeposit: BigNumber,
  poolId: number
): Promise<DeployStrategySushiswap> {
  const deployerSigner = await getDeployerSigner();

  let strategy: StrategySushiswap;
  if (deployedAddress) {
    strategy = StrategySushiswap__factory.connect(deployedAddress, deployerSigner);
  } else {
    const strategySushiswapFactory = (await ethers.getContractFactory(
      'StrategySushiswap'
    )) as StrategySushiswap__factory;
    strategy = await strategySushiswapFactory
      .connect(deployerSigner)
      .deploy(
        deployerSigner.address,
        supplyTokenAddress,
        pairTokenAddress,
        process.env.SUSHI_SWAP_ROUTER as string,
        process.env.SUSHI_MASTER_CHEF as string,
        process.env.SUSHI as string,
        maxSlippage,
        maxOneDeposit,
        poolId
      );
    await strategy.deployed();
  }

  const supplyToken = ERC20__factory.connect(supplyTokenAddress, deployerSigner);

  return { strategy, supplyToken, deployerSigner };
}

export async function testStrategySushiswap(
  context: Mocha.Context,
  deployedAddress: string | undefined,
  supplyTokenSymbol: string,
  supplyTokenDecimals: number,
  supplyTokenAddress: string,
  pairTokenAddress: string,
  maxSlippage: BigNumber,
  maxOneDeposit: BigNumber,
  poolId: number,
  supplyTokenFunder: string
): Promise<void> {
  context.timeout(300000);

  const { strategy, supplyToken, deployerSigner } = await deployStrategySushiswap(
    deployedAddress,
    supplyTokenAddress,
    pairTokenAddress,
    maxSlippage,
    maxOneDeposit,
    poolId
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

  console.log('===== Buy 10 =====');
  await expect(
    strategy.aggregateOrders(
      parseUnits('10', supplyTokenDecimals),
      parseUnits('0'),
      parseUnits('10', supplyTokenDecimals),
      parseUnits('0')
    )
  ).to.emit(strategy, 'Buy');

  const price1 = await strategy.getPrice();
  console.log('price1:', price1.toString());
  expect(price1).to.equal(parseUnits('1'));

  console.log('===== Sell 2 =====');
  await expect(
    strategy.aggregateOrders(
      parseUnits('0'),
      parseUnits('2', supplyTokenDecimals),
      parseUnits('0'),
      parseUnits('2', supplyTokenDecimals)
    )
  ).to.emit(strategy, 'Sell');

  const price2 = await strategy.getPrice();
  console.log('price2:', price2.toString());
  expect(price2).to.equal(price1);

  console.log('===== Buy 1, Sell 2 =====');
  await expect(
    strategy.aggregateOrders(
      parseUnits('1', supplyTokenDecimals),
      parseUnits('2', supplyTokenDecimals),
      parseUnits('1', supplyTokenDecimals),
      parseUnits('2', supplyTokenDecimals)
    )
  )
    .to.emit(strategy, 'Buy')
    .to.emit(strategy, 'Sell');
  const price3 = await strategy.getPrice();
  console.log('price3:', price3.toString());
  expect(price3).to.equal(price2);

  console.log('===== adjust =====');
  await strategy.adjust();
  const price4 = await strategy.getPrice();
  console.log('price4:', price4.toString());
  expect(price4).to.lt(price3);

  console.log('===== Buy 1, Sell 2 after adjust =====');
  await expect(
    strategy.aggregateOrders(
      parseUnits('1', supplyTokenDecimals),
      parseUnits('2', supplyTokenDecimals),
      parseUnits('1', supplyTokenDecimals),
      parseUnits('1', supplyTokenDecimals)
    )
  )
    .to.emit(strategy, 'Buy')
    .to.emit(strategy, 'Sell');
  const price5 = await strategy.getPrice();
  console.log('price5:', price5.toString());
  expect(price5).to.lt(price4);

  console.log('===== harvest =====');
  // Send some Sushi to the strategy
  const sushi = ERC20__factory.connect(process.env.SUSHI as string, deployerSigner);
  await network.provider.request({
    method: 'hardhat_impersonateAccount',
    params: [process.env.SUSHI_FUNDER]
  });
  await (
    await sushi
      .connect(await ethers.getSigner(process.env.SUSHI_FUNDER as string))
      .transfer(strategy.address, parseEther('0.01'))
  ).wait();
  await strategy.harvest();
  const price6 = await strategy.getPrice();
  console.log('price6:', price6.toString());
  expect(price6).to.gt(price5);
}
