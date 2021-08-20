import { expect } from 'chai';
import { BigNumber } from 'ethers';
import { ethers, network } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseUnits, parseEther } from '@ethersproject/units';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

import { ERC20 } from '../../typechain/ERC20';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyUniswapV2__factory } from '../../typechain/factories/StrategyUniswapV2__factory';
import { StrategyUniswapV2 } from '../../typechain/StrategyUniswapV2';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

interface DeployStrategyUniswapV2 {
  strategy: StrategyUniswapV2;
  supplyToken: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deployStrategyUniswapV2(
  deployedAddress: string | undefined,
  supplyTokenAddress: string,
  pairTokenAddress: string,
  maxSlippage: BigNumber,
  maxOneDeposit: BigNumber
): Promise<DeployStrategyUniswapV2> {
  const deployerSigner = await getDeployerSigner();

  let strategy: StrategyUniswapV2;
  if (deployedAddress) {
    strategy = StrategyUniswapV2__factory.connect(deployedAddress, deployerSigner);
  } else {
    const strategyUniswapV2Factory = (await ethers.getContractFactory(
      'StrategyUniswapV2'
    )) as StrategyUniswapV2__factory;
    strategy = await strategyUniswapV2Factory
      .connect(deployerSigner)
      .deploy(
        deployerSigner.address,
        supplyTokenAddress,
        pairTokenAddress,
        process.env.UNISWAP_V2_ROUTER as string,
        maxSlippage,
        maxOneDeposit
      );
    await strategy.deployed();
  }

  const supplyToken = ERC20__factory.connect(supplyTokenAddress, deployerSigner);

  return { strategy, supplyToken, deployerSigner };
}

export async function testStrategyUniswapV2(
  context: Mocha.Context,
  deployedAddress: string | undefined,
  supplyTokenSymbol: string,
  supplyTokenDecimals: number,
  supplyTokenAddress: string,
  pairTokenAddress: string,
  maxSlippage: BigNumber,
  maxOneDeposit: BigNumber,
  supplyTokenFunder: string
): Promise<void> {
  context.timeout(300000);

  const { strategy, supplyToken, deployerSigner } = await deployStrategyUniswapV2(
    deployedAddress,
    supplyTokenAddress,
    pairTokenAddress,
    maxSlippage,
    maxOneDeposit
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

  const price1 = await strategy.callStatic.syncPrice();
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

  const price2 = await strategy.callStatic.syncPrice();
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
  const price3 = await strategy.callStatic.syncPrice();
  console.log('price3:', price3.toString());
  expect(price3).to.equal(price2);

  console.log('===== adjust =====');
  await strategy.adjust();
  const price4 = await strategy.callStatic.syncPrice();
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
  const price5 = await strategy.callStatic.syncPrice();
  console.log('price5:', price5.toString());
  expect(price5).to.lt(price4);

  console.log('===== harvest =====');
  await strategy.harvest();
  const price6 = await strategy.callStatic.syncPrice();
  console.log('price6:', price6.toString());
}
