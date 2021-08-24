import { expect } from 'chai';
import { ethers } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseUnits } from '@ethersproject/units';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

import { ERC20 } from '../../typechain/ERC20';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyUniswapV3Gelato__factory } from '../../typechain/factories/StrategyUniswapV3Gelato__factory';
import { StrategyUniswapV3Gelato } from '../../typechain/StrategyUniswapV3Gelato.d';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

interface DeployStrategyUniswapV3GelatoInfo {
  strategy: StrategyUniswapV3Gelato;
  supplyToken: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deployStrategyUniswapV3Gelato(
  deployedAddress: string | undefined,
  supplyTokenAddress: string,
  gUniPoolAddress: string
): Promise<DeployStrategyUniswapV3GelatoInfo> {
  const deployerSigner = await getDeployerSigner();

  let strategy: StrategyUniswapV3Gelato;
  if (deployedAddress) {
    strategy = StrategyUniswapV3Gelato__factory.connect(deployedAddress, deployerSigner);
  } else {
    const strategyUniswapV3GelatoFactory = (await ethers.getContractFactory(
      'StrategyUniswapV3Gelato'
    )) as StrategyUniswapV3Gelato__factory;
    strategy = await strategyUniswapV3GelatoFactory
      .connect(deployerSigner)
      .deploy(
        supplyTokenAddress,
        gUniPoolAddress,
        process.env.GUNI_RESOLVER as string,
        process.env.GUNI_ROUTER as string,
        process.env.UNISWAP_V3_ROUTER as string,
        deployerSigner.address
      );
    await strategy.deployed();
  }

  const supplyToken = ERC20__factory.connect(supplyTokenAddress, deployerSigner);

  return { strategy, supplyToken, deployerSigner };
}

export async function testStrategyUniswapV3Gelato(
  context: Mocha.Context,
  deployedAddress: string | undefined,
  supplyTokenSymbol: string,
  supplyTokenDecimals: number,
  supplyTokenAddress: string,
  gUniPoolAddress: string,
  supplyTokenFunder: string
): Promise<void> {
  context.timeout(300000);

  const { strategy, supplyToken, deployerSigner } = await deployStrategyUniswapV3Gelato(
    deployedAddress,
    supplyTokenAddress,
    gUniPoolAddress
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
}
