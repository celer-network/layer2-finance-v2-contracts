import { expect } from 'chai';
import { ethers, network } from 'hardhat';
import { BigNumber } from 'ethers';

import { getAddress } from '@ethersproject/address';
import { parseEther, parseUnits } from '@ethersproject/units';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

import { ERC20 } from '../../typechain/ERC20';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyBarnBridgeCompoundUSDCPool__factory } from '../../typechain/factories/StrategyBarnBridgeCompoundUSDCPool__factory';
import { StrategyBarnBridgeCompoundUSDCPool } from '../../typechain/StrategyBarnBridgeCompoundUSDCPool';
import { StrategyBarnBridgeAavePool__factory } from '../../typechain/factories/StrategyBarnBridgeAavePool__factory';
import { StrategyBarnBridgeAavePool } from '../../typechain/StrategyBarnBridgeAavePool';
import { StrategyBarnBridgeCreamPool__factory } from '../../typechain/factories/StrategyBarnBridgeCreamPool__factory';
import { StrategyBarnBridgeCreamPool } from '../../typechain/StrategyBarnBridgeCreamPool';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

interface DeployStrategyBarnBridgePoolInfo {
  strategy: StrategyBarnBridgeCompoundUSDCPool | StrategyBarnBridgeAavePool | StrategyBarnBridgeCreamPool;
  supplyToken: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deployStrategyBarnBridgePool(
  lendingPool: string,
  deployedAddress: string | undefined,
  supplyTokenAddress: string,
  supplyTokenSymbol: string | undefined,
  juniorTokenAddress: string,
  providerAddress: string,
  yieldAddress: string
): Promise<DeployStrategyBarnBridgePoolInfo> {
  const deployerSigner = await getDeployerSigner();
  let strategy: StrategyBarnBridgeCompoundUSDCPool | StrategyBarnBridgeAavePool | StrategyBarnBridgeCreamPool;
  if (lendingPool === 'compound') {
    if (deployedAddress) {
      strategy = StrategyBarnBridgeCompoundUSDCPool__factory.connect(deployedAddress, deployerSigner);
    } else {
      const StrategyBarnBridgeCompoundUSDCPoolFactory = (await ethers.getContractFactory(
        'StrategyBarnBridgeCompoundUSDCPool'
      )) as StrategyBarnBridgeCompoundUSDCPool__factory;
      strategy = await StrategyBarnBridgeCompoundUSDCPoolFactory
        .connect(deployerSigner)
        .deploy(
          juniorTokenAddress,
          providerAddress,
          yieldAddress,
          supplyTokenAddress,
          deployerSigner.address
        ) as StrategyBarnBridgeCompoundUSDCPool;
      await strategy.deployed();
    }
  } else if (lendingPool === 'aave') {
    if (deployedAddress) {
      strategy = StrategyBarnBridgeAavePool__factory.connect(deployedAddress, deployerSigner);
    } else {
      const StrategyBarnBridgeAavePoolFactory = (await ethers.getContractFactory(
        'StrategyBarnBridgeAavePool'
      )) as StrategyBarnBridgeAavePool__factory;
      strategy = await StrategyBarnBridgeAavePoolFactory
        .connect(deployerSigner)
        .deploy(
          juniorTokenAddress,
          providerAddress,
          supplyTokenSymbol as string,
          yieldAddress,
          supplyTokenAddress,
          deployerSigner.address
        ) as StrategyBarnBridgeAavePool;
      await strategy.deployed();
    }
  } else { // lendingPool is cream
    if (deployedAddress) {
      strategy = StrategyBarnBridgeCreamPool__factory.connect(deployedAddress, deployerSigner);
    } else {
      const StrategyBarnBridgeCreamPoolFactory = (await ethers.getContractFactory(
        'StrategyBarnBridgeCreamPool'
      )) as StrategyBarnBridgeCreamPool__factory;
      strategy = await StrategyBarnBridgeCreamPoolFactory
        .connect(deployerSigner)
        .deploy(
          juniorTokenAddress,
          providerAddress,
          supplyTokenSymbol as string,
          yieldAddress,
          supplyTokenAddress,
          deployerSigner.address
        ) as StrategyBarnBridgeCreamPool;
      await strategy.deployed();
    }
  }

  const supplyToken = ERC20__factory.connect(supplyTokenAddress, deployerSigner);

  return { strategy, supplyToken, deployerSigner };
}

export async function testStrategyBarnBridgePool(
  context: Mocha.Context,
  lendingPool: string,
  deployedAddress: string | undefined,
  supplyTokenAddress: string,
  supplyTokenSymbol: string,
  supplyTokenDecimal: number,
  juniorTokenAddress: string,
  providerAddress: string,
  yieldAddress: string,
  supplyTokenFunder: string
): Promise<void> {
  context.timeout(300000);

  const { strategy, supplyToken, deployerSigner } = await deployStrategyBarnBridgePool(
    lendingPool,
    deployedAddress,
    supplyTokenAddress,
    supplyTokenSymbol,
    juniorTokenAddress,
    providerAddress,
    yieldAddress
  );

  expect(getAddress(await strategy.getAssetAddress())).to.equal(getAddress(supplyToken.address));

  const displayCommitAmount = '100';
  const commitAmount = parseUnits(displayCommitAmount, supplyTokenDecimal);
  await ensureBalanceAndApproval(
    supplyToken,
    supplyTokenSymbol as string,
    commitAmount,
    deployerSigner,
    strategy.address,
    supplyTokenFunder
  );

  console.log('===== Buy 5 =====');
  await expect(
    strategy.aggregateOrders(
      parseUnits('5', supplyTokenDecimal),
      parseUnits('0'),
      parseUnits('4.9', supplyTokenDecimal),
      parseUnits('0')
    )
  ).to.emit(strategy, 'Buy')
   .to.not.emit(strategy, 'Sell');
  const shares1 = await strategy.shares();
  const price1 = await strategy.getPrice();
  const assetAmount1 =  price1.mul(shares1).div(BigNumber.from(10).pow(18));
  console.log('shares1:', shares1.toString());
  console.log('price1:', price1.toString());
  console.log('assetAmount1', assetAmount1.toString());
  expect(assetAmount1).to.gte(parseUnits('4.9', supplyTokenDecimal)).to.lt(parseUnits('5.1', supplyTokenDecimal));

  console.log('===== Sell 2 =====');
  await expect(
    strategy.aggregateOrders(
      parseUnits('0'),
      parseUnits('2', supplyTokenDecimal),
      parseUnits('0'),
      parseUnits('1.9', supplyTokenDecimal)
    )
  ).to.emit(strategy, 'Sell')
   .to.not.emit(strategy, 'Buy');
  const shares2 = await strategy.shares();
  const price2 = await strategy.getPrice();
  const assetAmount2 =  price2.mul(shares2).div(BigNumber.from(10).pow(18));
  console.log('shares2:', shares2.toString());
  console.log('price2:', price2.toString());
  console.log('assetAmount2', assetAmount2.toString());
  expect(assetAmount2).to.gte(parseUnits('2.9', supplyTokenDecimal)).to.lt(parseUnits('3.1', supplyTokenDecimal));

  console.log('===== Buy 1, Sell 2 =====');
  await expect(
    strategy.aggregateOrders(
      parseUnits('1', supplyTokenDecimal),
      parseUnits('2', supplyTokenDecimal),
      parseUnits('0.9', supplyTokenDecimal),
      parseUnits('1.9', supplyTokenDecimal)
    )
  )
    .to.emit(strategy, 'Buy')
    .to.emit(strategy, 'Sell');
  const shares3 = await strategy.shares();
  const price3 = await strategy.getPrice();
  const assetAmount3 =  price3.mul(shares2).div(BigNumber.from(10).pow(18));
  console.log('shares3:', shares3.toString());
  console.log('price3:', price3.toString());
  console.log('assetAmount3', assetAmount3.toString());
  expect(assetAmount2).to.gte(parseUnits('2.9', supplyTokenDecimal)).to.lt(parseUnits('3.1', supplyTokenDecimal));

  if (lendingPool === 'aave') {
    console.log('===== harvest, and price should be updated =====');
    try {
      // Send some BOND to the strategy
      const bond = ERC20__factory.connect(process.env.BOND as string, deployerSigner);
      await network.provider.request({
        method: 'hardhat_impersonateAccount',
        params: [process.env.BOND_FUNDER as string]
      });
      await (
        await bond
          .connect(await ethers.getSigner(process.env.BOND_FUNDER as string))
          .transfer(strategy.address, parseEther('0.01'))
        ).wait();
      // Send some AAVE to the strategy
      const aave = ERC20__factory.connect(process.env.AAVE as string, deployerSigner);
      await network.provider.request({
        method: 'hardhat_impersonateAccount',
        params: [process.env.AAVE_FUNDER as string]
      });
      await (
        await aave
          .connect(await ethers.getSigner(process.env.AAVE_FUNDER as string))
          .transfer(strategy.address, parseEther('0.1'))
      ).wait();
      const harvestGas = await strategy.estimateGas.harvest();
        if (harvestGas.lte(2000000)) {
          const harvestTx = await strategy.harvest({ gasLimit: 2000000 });
          const receipt = await harvestTx.wait();
          console.log('Harvest gas used:', receipt.gasUsed.toString());
          const price4 = await strategy.getPrice();
          console.log(`price4:`, price4.toString());
          expect(price4).to.gte(price3);
        }
    } catch (e) {
      console.log('Cannot harvest:', e);
    }
  } else if (lendingPool === 'compound' || lendingPool === 'cream'){
    console.log('===== harvest, and price should be updated =====');
    try {
      // Send some BOND to the strategy
      const bond = ERC20__factory.connect(process.env.BOND as string, deployerSigner);
      await network.provider.request({
        method: 'hardhat_impersonateAccount',
        params: [process.env.BOND_FUNDER as string]
      });
      await (
        await bond
          .connect(await ethers.getSigner(process.env.BOND_FUNDER as string))
          .transfer(strategy.address, parseEther('0.01'))
        ).wait();
      const harvestGas = await strategy.estimateGas.harvest();
      if (harvestGas.lte(2000000)) {
        const harvestTx = await strategy.harvest({ gasLimit: 2000000 });
        const receipt = await harvestTx.wait();
        console.log('Harvest gas used:', receipt.gasUsed.toString());
        const price4 = await strategy.getPrice();
        console.log(`price4:`, price4.toString());
        expect(price4).to.gte(price3);
      }
    } catch (e) {
      console.log('Cannot harvest:', e);
    }
  }
}
