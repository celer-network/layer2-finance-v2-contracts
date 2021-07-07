import { expect } from 'chai';
import { ethers, network } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseEther, parseUnits } from '@ethersproject/units';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

import { ERC20 } from '../../typechain/ERC20.d';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyCompoundErc20LendingPool__factory } from '../../typechain/factories/StrategyCompoundErc20LendingPool__factory';
import { StrategyCompoundErc20LendingPool } from '../../typechain/StrategyCompoundErc20LendingPool';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

interface DeployStrategyCompoundErc20LendingPoolInfo {
  strategy: StrategyCompoundErc20LendingPool;
  supplyToken: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deployStrategyCompoundErc20LendingPool(
  deployedAddress: string | undefined,
  supplyTokenSymbol: string,
  supplyTokenAddress: string,
  compoundSupplyTokenAddress: string
): Promise<DeployStrategyCompoundErc20LendingPoolInfo> {
  const deployerSigner = await getDeployerSigner();

  let strategy: StrategyCompoundErc20LendingPool;
  if (deployedAddress) {
    strategy = StrategyCompoundErc20LendingPool__factory.connect(deployedAddress, deployerSigner);
  } else {
    const strategyCompoundErc20LendingPoolFactory = (await ethers.getContractFactory(
      'StrategyCompoundErc20LendingPool'
    )) as StrategyCompoundErc20LendingPool__factory;
    strategy = await strategyCompoundErc20LendingPoolFactory
      .connect(deployerSigner)
      .deploy(
        supplyTokenAddress,
        compoundSupplyTokenAddress,
        process.env.COMPOUND_COMPTROLLER as string,
        process.env.COMPOUND_COMP as string,
        process.env.UNISWAP_ROUTER as string,
        process.env.WETH as string,
        deployerSigner.address
      );
    await strategy.deployed();
  }

  const supplyToken = ERC20__factory.connect(supplyTokenAddress, deployerSigner);

  return { strategy, supplyToken, deployerSigner };
}

export async function testStrategyCompoundErc20LendingPool(
  context: Mocha.Context,
  deployedAddress: string | undefined,
  supplyTokenSymbol: string,
  supplyTokenDecimals: number,
  supplyTokenAddress: string,
  compoundSupplyTokenAddress: string,
  supplyTokenFunder: string
): Promise<void> {
  context.timeout(300000);

  const { strategy, supplyToken, deployerSigner } = await deployStrategyCompoundErc20LendingPool(
    deployedAddress,
    supplyTokenSymbol,
    supplyTokenAddress,
    compoundSupplyTokenAddress
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
  await expect(strategy.aggregateOrders(parseUnits('5', supplyTokenDecimals), parseUnits('0'), parseUnits('5', supplyTokenDecimals), parseUnits('0')))
    .to.emit(strategy, 'Buy')
    .withArgs(parseUnits('5', supplyTokenDecimals), parseUnits('5', supplyTokenDecimals));

  expect(await strategy.shares()).to.equal(parseUnits('5', supplyTokenDecimals));
  const price1 = await strategy.callStatic.syncPrice();
  console.log('price1:', price1.toString());
  expect(price1).to.lte(parseUnits('1'));

  console.log('===== Sell 2 =====');
  await expect(strategy.aggregateOrders(parseUnits('0'), parseUnits('2', supplyTokenDecimals), parseUnits('0'), parseUnits('2', supplyTokenDecimals)))
  .to.emit(strategy, 'Sell');
  expect(await strategy.shares()).to.equal(parseUnits('3', supplyTokenDecimals));
  const price2 = await strategy.callStatic.syncPrice();
  console.log('price2:', price2.toString());
  expect(price2).to.gte(price1);

  console.log('===== Buy 1, Sell 2 =====');
  await expect(strategy.aggregateOrders(parseUnits('1', supplyTokenDecimals), parseUnits('2', supplyTokenDecimals), parseUnits('1', supplyTokenDecimals), parseUnits('2', supplyTokenDecimals)))
    .to.emit(strategy, 'Sell');
  expect(await strategy.shares()).to.lte(parseUnits('2', supplyTokenDecimals));
  const price3 = await strategy.callStatic.syncPrice();
  console.log('price3:', price3.toString());
  expect(price3).to.gte(price2);
  
  console.log('===== harvest, and price should be updated =====');
  try {
    // Send some COMP to the strategy
    const comp = ERC20__factory.connect(process.env.COMPOUND_COMP as string, deployerSigner);
    await network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [process.env.COMPOUND_COMP_FUNDER]
    });
    await (
      await comp
        .connect(await ethers.getSigner(process.env.COMPOUND_COMP_FUNDER as string))
        .transfer(strategy.address, parseEther('0.01'))
    ).wait();
    console.log('===== Sent COMP to the strategy, harvesting =====');
    const harvestGas = await strategy.estimateGas.harvest();
    if (harvestGas.lte(2000000)) {
      const harvestTx = await strategy.harvest({ gasLimit: 2000000 });
      const receipt = await harvestTx.wait();
      console.log('Harvest gas used:', receipt.gasUsed.toString());
      const price4 =  await strategy.callStatic.syncPrice();
      console.log(
        `price4:`, price4.toString()
      );
      expect(price4).to.gte(price3);
    }
  } catch (e) {
    console.log('Cannot harvest:', e);
  }
}
