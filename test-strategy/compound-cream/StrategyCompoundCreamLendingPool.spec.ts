import { expect } from 'chai';
import { ethers, network } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseEther, parseUnits } from '@ethersproject/units';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

import { ICErc20__factory } from '../../typechain';
import { ERC20 } from '../../typechain/ERC20';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyCompoundCreamLendingPool__factory } from '../../typechain/factories/StrategyCompoundCreamLendingPool__factory';
import { StrategyCompoundCreamLendingPool } from '../../typechain/StrategyCompoundCreamLendingPool';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

interface DeployStrategyCompoundCreamLendingPoolInfo {
  strategy: StrategyCompoundCreamLendingPool;
  supplyToken: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deployStrategyCompoundCreamLendingPool(
  deployedAddress: string | undefined,
  supplyTokenAddress: string,
  compoundSupplyTokenAddress: string,
  creamSupplyTokenAddress: string
): Promise<DeployStrategyCompoundCreamLendingPoolInfo> {
  const deployerSigner = await getDeployerSigner();

  let strategy: StrategyCompoundCreamLendingPool;
  if (deployedAddress) {
    strategy = StrategyCompoundCreamLendingPool__factory.connect(deployedAddress, deployerSigner);
  } else {
    const strategyCompoundCreamLendingPoolFactory = (await ethers.getContractFactory(
      'StrategyCompoundCreamLendingPool'
    )) as StrategyCompoundCreamLendingPool__factory;
    strategy = await strategyCompoundCreamLendingPoolFactory
      .connect(deployerSigner)
      .deploy(
        supplyTokenAddress,
        compoundSupplyTokenAddress,
        creamSupplyTokenAddress,
        process.env.COMPOUND_COMPTROLLER as string,
        process.env.CREAM_COMPTROLLER as string,
        process.env.COMPOUND_COMP as string,
        process.env.CREAM_CREAM as string,
        process.env.UNISWAP_V2_ROUTER as string,
        process.env.WETH as string,
        deployerSigner.address
      );
    await strategy.deployed();
  }

  const supplyToken = ERC20__factory.connect(supplyTokenAddress, deployerSigner);

  return { strategy, supplyToken, deployerSigner };
}

export async function testStrategyCompoundCreamLendingPool(
  context: Mocha.Context,
  deployedAddress: string | undefined,
  supplyTokenSymbol: string,
  supplyTokenDecimals: number,
  supplyTokenAddress: string,
  compoundSupplyTokenAddress: string,
  creamSupplyTokenAddress: string,
  supplyTokenFunder: string
): Promise<void> {
  context.timeout(300000);

  const { strategy, supplyToken, deployerSigner } = await deployStrategyCompoundCreamLendingPool(
    deployedAddress,
    supplyTokenAddress,
    compoundSupplyTokenAddress,
    creamSupplyTokenAddress
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
  await expect(
    strategy.aggregateOrders(
      parseUnits('5', supplyTokenDecimals),
      parseUnits('0'),
      parseUnits('4', supplyTokenDecimals),
      parseUnits('0')
    )
  ).to.emit(strategy, 'Buy');

  const price1 = await strategy.getPrice();
  console.log('price1:', price1.toString());
  expect(price1).to.lte(parseUnits('1'));

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
  expect(price2).to.gte(price1);

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
  expect(await strategy.shares()).to.lte(parseUnits('2', supplyTokenDecimals));
  const price3 = await strategy.getPrice();
  console.log('price3:', price3.toString());
  expect(price3).to.gte(price2);

  console.log('===== Add 1 for low rate protocol  =====');
  const cErc20 = ICErc20__factory.connect(compoundSupplyTokenAddress, deployerSigner);
  const crErc20 = ICErc20__factory.connect(creamSupplyTokenAddress, deployerSigner);
  const cErc20Rate = await cErc20.callStatic.supplyRatePerBlock();
  console.log(`cErc20Rate:`, cErc20Rate.toString());
  const crErc20Rate = await crErc20.callStatic.supplyRatePerBlock();
  console.log(`crErc20Rate:`, crErc20Rate.toString());

  await network.provider.request({
    method: 'hardhat_impersonateAccount',
    params: [strategy.address]
  });
  (
    await deployerSigner.sendTransaction({
      to: strategy.address,
      value: parseEther('0.01')
    })
  ).wait();
  const toMint = parseUnits('1', supplyTokenDecimals);
  await (await supplyToken.transfer(strategy.address, toMint)).wait();
  if (cErc20Rate > crErc20Rate) {
    await (
      await supplyToken.connect(await ethers.getSigner(strategy.address)).approve(creamSupplyTokenAddress, toMint)
    ).wait();
    await (await crErc20.connect(await ethers.getSigner(strategy.address)).mint(toMint)).wait();
  } else if (cErc20Rate < crErc20Rate) {
    await (
      await supplyToken.connect(await ethers.getSigner(strategy.address)).approve(compoundSupplyTokenAddress, toMint)
    ).wait();
    await (await cErc20.connect(await ethers.getSigner(strategy.address)).mint(toMint)).wait();
  }

  console.log('===== Sell 0.5 =====');
  let cErc20Balance = await cErc20.callStatic.balanceOfUnderlying(strategy.address);
  let crErc20Balance = await crErc20.callStatic.balanceOfUnderlying(strategy.address);
  console.log(`before sell: cErc20Balance ${cErc20Balance.toString()}, crErc20Balance ${crErc20Balance.toString()}`);
  await expect(
    strategy.aggregateOrders(
      parseUnits('0'),
      parseUnits('0.5', supplyTokenDecimals),
      parseUnits('0'),
      parseUnits('0.5', supplyTokenDecimals)
    )
  ).to.emit(strategy, 'Sell');
  const price4 = await strategy.getPrice();
  console.log('price4:', price4.toString());
  expect(price4).to.gte(price3);

  console.log('===== adjust =====');
  cErc20Balance = await cErc20.callStatic.balanceOfUnderlying(strategy.address);
  crErc20Balance = await crErc20.callStatic.balanceOfUnderlying(strategy.address);
  console.log(`before adjust: cErc20Balance ${cErc20Balance.toString()}, crErc20Balance ${crErc20Balance.toString()}`);
  await strategy.adjust();
  cErc20Balance = await cErc20.callStatic.balanceOfUnderlying(strategy.address);
  crErc20Balance = await crErc20.callStatic.balanceOfUnderlying(strategy.address);
  console.log(`after adjust: cErc20Balance ${cErc20Balance.toString()}, crErc20Balance ${crErc20Balance.toString()}`);
  if (cErc20Rate < crErc20Rate) {
    expect(cErc20Balance).equals(0);
  } else if (cErc20Rate > crErc20Rate) {
    expect(crErc20Balance).equals(0);
  }

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
    console.log('===== harvesting =====');
    const harvestTx = await strategy.harvest({ gasLimit: 2000000 });
    const receipt = await harvestTx.wait();
    console.log('Harvest gas used:', receipt.gasUsed.toString());
    const price5 = await strategy.getPrice();
    console.log(`price5:`, price5.toString());
    expect(price5).to.gte(price4);
  } catch (e) {
    console.log('Cannot harvest:', e);
  }
}
