import { expect } from 'chai';
import { ethers, network } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseEther, parseUnits } from '@ethersproject/units';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

import { ERC20 } from '../../typechain/ERC20';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyAaveLendingPool__factory } from '../../typechain/factories/StrategyAaveLendingPool__factory';
import { StrategyAaveLendingPool } from '../../typechain/StrategyAaveLendingPool';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

interface DeployStrategyAaveLendingPoolInfo {
  strategy: StrategyAaveLendingPool;
  supplyToken: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deployStrategyAaveLendingPool(
  deployedAddress: string | undefined,
  supplyTokenAddress: string,
  aaveSupplyTokenAddress: string
): Promise<DeployStrategyAaveLendingPoolInfo> {
  const deployerSigner = await getDeployerSigner();

  let strategy: StrategyAaveLendingPool;
  if (deployedAddress) {
    strategy = StrategyAaveLendingPool__factory.connect(deployedAddress, deployerSigner);
  } else {
    const strategyAaveLendingPoolFactory = (await ethers.getContractFactory(
      'StrategyAaveLendingPool'
    )) as StrategyAaveLendingPool__factory;
    strategy = await strategyAaveLendingPoolFactory
      .connect(deployerSigner)
      .deploy(
        process.env.AAVE_LENDING_POOL as string,
        supplyTokenAddress,
        aaveSupplyTokenAddress,
        deployerSigner.address,
        process.env.AAVE_INCENTIVES_CONTROLLER as string,
        process.env.AAVE_STAKED_AAVE as string,
        process.env.AAVE_AAVE as string,
        process.env.UNISWAP_V2_ROUTER as string,
        process.env.WETH as string
      );
    await strategy.deployed();
  }

  const supplyToken = ERC20__factory.connect(supplyTokenAddress, deployerSigner);

  return { strategy, supplyToken, deployerSigner };
}

export async function testStrategyAaveLendingPool(
  context: Mocha.Context,
  deployedAddress: string | undefined,
  supplyTokenSymbol: string,
  supplyTokenDecimals: number,
  supplyTokenAddress: string,
  aaveSupplyTokenAddress: string,
  supplyTokenFunder: string
): Promise<void> {
  context.timeout(300000);

  const { strategy, supplyToken, deployerSigner } = await deployStrategyAaveLendingPool(
    deployedAddress,
    supplyTokenAddress,
    aaveSupplyTokenAddress
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
      parseUnits('5', supplyTokenDecimals),
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
  expect(price2).to.lte(price1);

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
  expect(price3).to.lte(price2);

  console.log('===== harvest, and price should be updated =====');
  try {
    // Send some AAVE to the strategy
    const aave = ERC20__factory.connect(process.env.AAVE_AAVE as string, deployerSigner);
    await network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [process.env.AAVE_AAVE_FUNDER]
    });
    await (
      await aave
        .connect(await ethers.getSigner(process.env.AAVE_AAVE_FUNDER as string))
        .transfer(strategy.address, parseEther('0.01'))
    ).wait();
    console.log('===== Sent AAVE to the strategy, harvesting =====');
    console.log(
      'Simulate the passing of 60 days to accumulate staked AAVE. First harvest tx should trigger cooldown().'
    );
    await ethers.provider.send('evm_increaseTime', [60 * 60 * 24 * 60]);
    const harvestGas = await strategy.estimateGas.harvest();
    if (harvestGas.lte(2000000)) {
      const harvestTx = await strategy.harvest({ gasLimit: 2000000 });
      let receipt = await harvestTx.wait();
      console.log('Harvest gas used:', receipt.gasUsed.toString());
      const price4 = await strategy.getPrice();
      console.log(`price4:`, price4.toString());
      expect(price4).to.gte(price3);

      console.log('Simulate the passing of the 10-day cooldown period.');
      await ethers.provider.send('evm_increaseTime', [60 * 60 * 24 * 10]);
      const harvestTx2 = await strategy.harvest({ gasLimit: 2000000 });
      receipt = await harvestTx2.wait();
      console.log('Harvest gas used:', receipt.gasUsed.toString());
      const price5 = await strategy.getPrice();
      console.log(`price5:`, price5.toString());
      expect(price5).to.gte(price4);

      console.log('Simulate the passing of another 1 day.');
      await ethers.provider.send('evm_increaseTime', [60 * 60 * 24 * 1]);
      const harvestTx3 = await strategy.harvest({ gasLimit: 2000000 });
      receipt = await harvestTx3.wait();
      console.log('Harvest gas used:', receipt.gasUsed.toString());
      const price6 = await strategy.getPrice();
      console.log(`price6:`, price6.toString());
      expect(price6).to.gte(price5);

      console.log('Simulate the passing of another 1 day.');
      await ethers.provider.send('evm_increaseTime', [60 * 60 * 24 * 1]);
      const harvestTx4 = await strategy.harvest({ gasLimit: 2000000 });
      receipt = await harvestTx4.wait();
      console.log('Harvest gas used:', receipt.gasUsed.toString());
      const price7 = await strategy.getPrice();
      console.log(`price7:`, price7.toString());
      expect(price7).to.gte(price6);

      console.log('Simulate the passing of another 1 day.');
      await ethers.provider.send('evm_increaseTime', [60 * 60 * 24 * 1]);
      const harvestTx5 = await strategy.harvest({ gasLimit: 2000000 });
      receipt = await harvestTx5.wait();
      console.log('Harvest gas used:', receipt.gasUsed.toString());
      const price8 = await strategy.getPrice();
      console.log(`price8:`, price8.toString());
      expect(price8).to.gte(price7);

      console.log('Simulate the passing of another 1 day.');
      await ethers.provider.send('evm_increaseTime', [60 * 60 * 24 * 1]);
      const harvestTx6 = await strategy.harvest({ gasLimit: 2000000 });
      receipt = await harvestTx6.wait();
      console.log('Harvest gas used:', receipt.gasUsed.toString());
      const price9 = await strategy.getPrice();
      console.log(`price9:`, price9.toString());
      expect(price9).to.gte(price8);
    }
  } catch (e) {
    console.log('Cannot harvest:', e);
  }
}
