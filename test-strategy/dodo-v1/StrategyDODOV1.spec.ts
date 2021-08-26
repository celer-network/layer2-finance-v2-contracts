import { expect } from 'chai';
import { ethers, network } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseEther, parseUnits } from '@ethersproject/units';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

import { ERC20 } from '../../typechain/ERC20';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyDODOV1__factory } from '../../typechain/factories/StrategyDODOV1__factory';
import { StrategyDODOV1 } from '../../typechain/StrategyDODOV1.d';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

interface DeployStrategyDODOV1Info {
  strategy: StrategyDODOV1;
  supplyToken: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deployStrategyDODOV1(
  deployedAddress: string | undefined,
  supplyTokenAddress: string,
  dodoPairAddress: string
): Promise<DeployStrategyDODOV1Info> {
  const deployerSigner = await getDeployerSigner();

  let strategy: StrategyDODOV1;
  if (deployedAddress) {
    strategy = StrategyDODOV1__factory.connect(deployedAddress, deployerSigner);
  } else {
    const strategyDODOV1Factory = (await ethers.getContractFactory('StrategyDODOV1')) as StrategyDODOV1__factory;
    strategy = await strategyDODOV1Factory
      .connect(deployerSigner)
      .deploy(
        supplyTokenAddress,
        process.env.DODO as string,
        process.env.USDT as string,
        dodoPairAddress,
        process.env.DODO_PROXY as string,
        process.env.DODO_MINE as string,
        process.env.DODO_APPROVE as string,
        process.env.DODO_V1_DODO_USDT as string,
        process.env.UNISWAP_V2_ROUTER as string,
        deployerSigner.address
      );
    await strategy.deployed();
  }

  const supplyToken = ERC20__factory.connect(supplyTokenAddress, deployerSigner);

  return { strategy, supplyToken, deployerSigner };
}

export async function testStrategyDODOV1(
  context: Mocha.Context,
  deployedAddress: string | undefined,
  supplyTokenSymbol: string,
  supplyTokenDecimals: number,
  supplyTokenAddress: string,
  dodoPairAddress: string,
  supplyTokenFunder: string
): Promise<void> {
  context.timeout(300000);

  const { strategy, supplyToken, deployerSigner } = await deployStrategyDODOV1(
    deployedAddress,
    supplyTokenAddress,
    dodoPairAddress
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
  strategy;
  await expect(
    strategy.aggregateOrders(
      parseUnits('10', supplyTokenDecimals),
      parseUnits('0'),
      parseUnits('9.95', supplyTokenDecimals),
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
      parseUnits('1.95', supplyTokenDecimals)
    )
  ).to.emit(strategy, 'Sell');

  const price2 = await strategy.getPrice();
  console.log('price2:', price2.toString());
  // TODO: Add price check

  console.log('===== Buy 1, Sell 2 =====');
  await expect(
    strategy.aggregateOrders(
      parseUnits('1', supplyTokenDecimals),
      parseUnits('2', supplyTokenDecimals),
      parseUnits('0.95', supplyTokenDecimals),
      parseUnits('1.95', supplyTokenDecimals)
    )
  )
    .to.emit(strategy, 'Buy')
    .to.emit(strategy, 'Sell');
  const price3 = await strategy.getPrice();
  console.log('price3:', price3.toString());
  // TODO: Add price check

  console.log('===== harvest =====');
  await strategy.setHarvestThreshold(parseEther('0.01'));
  // Send some DODO to the strategy
  const dodo = ERC20__factory.connect(process.env.DODO as string, deployerSigner);
  await network.provider.request({
    method: 'hardhat_impersonateAccount',
    params: [process.env.DODO_FUNDER]
  });
  await (
    await dodo
      .connect(await ethers.getSigner(process.env.DODO_FUNDER as string))
      .transfer(strategy.address, parseEther('0.05'))
  ).wait();
  await strategy.harvest();
  const price4 = await strategy.getPrice();
  console.log('price4:', price4.toString());
  // TODO: Add price check
}
