import { getAddress } from '@ethersproject/address';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';
import { expect } from 'chai';
import * as dotenv from 'dotenv';
import { BigNumber } from 'ethers';
import { parseEther, parseUnits } from 'ethers/lib/utils';
import { ethers } from 'hardhat';
import { StrategyIdleLendingPool__factory } from '../../typechain';
import { ERC20 } from '../../typechain/ERC20';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyIdleLendingPool } from '../../typechain/StrategyIdleLendingPool';
import { GovTokenRegistry__factory } from '../../typechain/factories/GovTokenRegistry__factory';
import { GovTokenRegistry } from '../../typechain/GovTokenRegistry';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

dotenv.config();

interface DeployStrategyIdleLendingPoolInfo {
    strategy: StrategyIdleLendingPool;
    supplyTokenContract: ERC20;
    deployerSigner: SignerWithAddress;
}

async function deployGovTokenRegistry(
    deployedAddress: string | undefined,
): Promise<GovTokenRegistry> {
    const deployerSigner = await getDeployerSigner();

    let govTokenRegistry: GovTokenRegistry;
    if(deployedAddress) {
        govTokenRegistry = GovTokenRegistry__factory.connect(deployedAddress, deployerSigner);
    } else {
        const govTokenRegistryFactory = (await ethers.getContractFactory(
            'GovTokenRegistry'
        )) as GovTokenRegistry__factory;
        govTokenRegistry = await govTokenRegistryFactory
            .connect(deployerSigner)
            .deploy(
                process.env.COMPOUND_COMP as string,
                process.env.IDLE_IDLE as string,
                process.env.AAVE_AAVE as string
            );
        await govTokenRegistry.deployed();
    }
    return govTokenRegistry;
}

async function deployStrategyIdleLendingPool(
    deployedAddress: string | undefined,
    supplyTokenSymbol: string,
    supplyTokenAddress: string,
    supplyTokenDecimal: number,
    idleTokenAddress: string,
    govTokenRegistryAddress: string
): Promise<DeployStrategyIdleLendingPoolInfo> {
    const deployerSigner = await getDeployerSigner();

    let strategy: StrategyIdleLendingPool;
    if (deployedAddress) {
        strategy = StrategyIdleLendingPool__factory.connect(deployedAddress, deployerSigner);
    } else {
        const strategyIdleLendingPoolFactory = (await ethers.getContractFactory(
            'StrategyIdleLendingPool'
        )) as StrategyIdleLendingPool__factory;
        strategy = await strategyIdleLendingPoolFactory
            .connect(deployerSigner)
            .deploy(
                idleTokenAddress,
                supplyTokenSymbol,
                supplyTokenAddress,
                supplyTokenDecimal,
                govTokenRegistryAddress,
                process.env.AAVE_STAKED_AAVE as string,
                process.env.WETH as string,
                process.env.SUSHISWAP_ROUTER as string,
                deployerSigner.address
            );
        await strategy.deployed();
    }

    const supplyTokenContract = ERC20__factory.connect(supplyTokenAddress, deployerSigner)

    return { strategy, supplyTokenContract, deployerSigner };
}

const getUnitParser = (decimals: number) => {
    return (value: string) => {
      return parseUnits(value, decimals);
    };
};

export async function testStrategyIdleLendingPool(
    context: Mocha.Context,
    deployedAddress: string | undefined,
    supplyTokenSymbol: string,
    supplyTokenAddress: string,
    supplyTokenDecimal: number,
    idleTokenAddress: string,
    supplyTokenFunder: string
): Promise<void> {
    context.timeout(300000);

    const govTokenRegistry = await deployGovTokenRegistry(deployedAddress);
    const { strategy, supplyTokenContract, deployerSigner } = await deployStrategyIdleLendingPool(
        deployedAddress,
        supplyTokenSymbol,
        supplyTokenAddress,
        supplyTokenDecimal,
        idleTokenAddress,
        govTokenRegistry.address
    );

    const p = getUnitParser(supplyTokenDecimal);

    console.log('\n>>> ensuring contract deployment');
    const assetAddress = getAddress(await strategy.getAssetAddress());
    console.log('----- asset address', assetAddress);
    expect(assetAddress).to.equal(getAddress(supplyTokenAddress));
    const price = await strategy.callStatic.syncPrice();
    console.log('----- price after contract deployment', price.toString());
    expect(price).to.equal(parseEther('1'));

    console.log('\n>>> ensuring balance and approval...');
    const fundAmount = parseUnits('500', supplyTokenDecimal);
    const supplyTokenBalanceBefore = await supplyTokenContract.balanceOf(deployerSigner.address);
    console.log('----- supplyTokenBalance', supplyTokenBalanceBefore.toString());
    await ensureBalanceAndApproval(
        supplyTokenContract,
        supplyTokenSymbol,
        fundAmount,
        deployerSigner,
        strategy.address,
        supplyTokenFunder
    );
    const supplyTokenBalance = await supplyTokenContract.balanceOf(deployerSigner.address);
    console.log('----- supplyTokenBalance', supplyTokenBalance.toString());

    console.log('\n>>> aggregateOrders #1 -> buy 500 sell 0');
    const aggregateOrders1Gas = await strategy.estimateGas.aggregateOrders(p('500'), p('0'), p('99'), p('0'));
    console.log('----- estimated gas =', aggregateOrders1Gas.toString());
    expect(aggregateOrders1Gas).to.lt(1250000);
    await expect(await strategy.aggregateOrders(p('500'), p('0'), p('99'), p('0')))
        .to.emit(strategy, 'Buy')
        .to.not.emit(strategy, 'Sell');
    const shares2 = await strategy.shares();
    console.log('----- shares =', shares2.toString());
    const price2 = await strategy.callStatic.syncPrice();
    console.log('----- price =', price2.toString());
    const assetAmount2 = price2.mul(shares2).div(BigNumber.from(10).pow(18));
    expect(assetAmount2).to.gte(p('499.9')).to.lte(p('501'));
    console.log('----- assetAmount =', assetAmount2.toString());

    console.log('\n>>> aggregateOrders #2 -> buy 0 sell 250');
    const aggregateOrders2Gas = await strategy.estimateGas.aggregateOrders(p('0'), p('250'), p('0'), p('249'));
    console.log('----- estimated gas =', aggregateOrders2Gas.toString());
    expect(aggregateOrders2Gas).to.lt(1250000);
    await expect(strategy.aggregateOrders(p('0'), p('250'), p('0'), p('249')))
        .to.emit(strategy, 'Sell')
        .to.not.emit(strategy, 'Buy');
    const shares3 = await strategy.shares();
    console.log('----- shares =', shares3.toString());
    const price3 = await strategy.callStatic.syncPrice();
    console.log('----- price =', price3.toString());
    const assetAmount3 = price3.mul(shares3).div(BigNumber.from(10).pow(18));
    expect(assetAmount3).to.gte(p('249.9')).to.lte(p('251'));
    console.log('----- assetAmount =', assetAmount3.toString());

    console.log('\n>>> aggregateOrders #3 -> buy 250 sell 100');
    const aggregateOrders3Gas = await strategy.estimateGas.aggregateOrders(p('250'), p('100'), p('249'), p('99'));
    console.log('----- estimated gas =', aggregateOrders3Gas.toString());
    expect(aggregateOrders3Gas).to.lt(1250000);
    await expect(strategy.aggregateOrders(p('250'), p('100'), p('249'), p('99')))
        .to.emit(strategy, 'Buy')
        .to.emit(strategy, 'Sell');
    const shares4 = await strategy.shares();
    console.log('----- shares =', shares4.toString());
    const price4 = await strategy.callStatic.syncPrice();
    console.log('----- price =', price4.toString());
    const assetAmount4 = price4.mul(shares4).div(BigNumber.from(10).pow(18));
    expect(assetAmount4).to.gte(p('399.9')).to.lt(p('400.1'));
    console.log('----- assetAmount =', assetAmount4.toString());

    console.log('\n>>> aggregateOrders #4 -> buy 10 sell 500 (oversell)');
    await expect(strategy.aggregateOrders(p('10'), p('500'), p('9'), p('499'))).to.revertedWith('not enough shares to sell');
    console.log('----- successfully reverted');

    console.log('\n>>> aggregateOrders #4 -> buy 10 minBuy 11 (fail min buy)');
    await expect(strategy.aggregateOrders(p('10'), p('0'), p('11'), p('0'))).to.revertedWith(
      'failed min shares from buy'
    );
    console.log('----- successfully reverted');

    console.log('\n>>> aggregateOrders #4 -> sell 10 minSell 11 (fail min sell)');
    await expect(strategy.aggregateOrders(p('0'), p('10'), p('0'), p('11'))).to.revertedWith(
      'failed min amount from sell'
    );
    console.log('----- successfully reverted');

    const harvestGas = await strategy.estimateGas.harvest();
    console.log('\n>>> estimated harvest gas =', harvestGas.toString());
    if (harvestGas.gt(2000000)) {
        console.log('Harvest gas is greater than 2mil!');
    }

    console.log('\n>>> harvest #1 after 1 days');
    await ethers.provider.send('evm_increaseTime', [60 * 60 * 24]);
    const harvestTx = await strategy.harvest();
    const receipt = await harvestTx.wait();
    console.log('---- gas used =', receipt.gasUsed.toString());
    const price5 = await strategy.callStatic.syncPrice();
    const shares5 = await strategy.shares();
    const assetAmount5 = price5.mul(shares4).div(BigNumber.from(10).pow(18));
    console.log('---- shares =', shares5.toString());
    console.log('---- price =', price5.toString());
    console.log('---- assetAmount =', assetAmount5.toString());
    expect(shares5).to.eq(shares4);
    expect(assetAmount5).to.gte(assetAmount4);

    console.log('\n>>> harvest #2 after another 1 days');
    await ethers.provider.send('evm_increaseTime', [60 * 60 * 24]);
    const harvestTx2 = await strategy.harvest({ gasLimit: 2000000 });
    const receipt2 = await harvestTx2.wait();
    console.log('---- gas used =', receipt2.gasUsed.toString());
    const price6 = await strategy.callStatic.syncPrice();
    const shares6 = await strategy.shares();
    const assetAmount6 = price6.mul(shares6).div(BigNumber.from(10).pow(18));
    console.log('---- shares =', shares6.toString());
    console.log('---- price =', price6.toString());
    console.log('---- assetAmount =', assetAmount6.toString());
    expect(shares6).to.eq(shares5);
    expect(assetAmount6).to.gte(assetAmount5);

    console.log('\n>>> register governance token to GovTokenRegistry');
    await expect(govTokenRegistry.registerGovToken('0xc84f7abe4904ee4f20a8c5dfa3cc4bf1829330ab'))
        .to.emit(govTokenRegistry, 'GovTokenRegistered');
    const govTokenLength = await govTokenRegistry.callStatic.getGovTokensLength();
    expect(govTokenLength).to.eq(4);

    console.log('\n>>> unregister governance token from GovTokenRegistry');
    await expect(govTokenRegistry.unregisterGovToken('0xc84f7abe4904ee4f20a8c5dfa3cc4bf1829330ab'))
        .to.emit(govTokenRegistry, 'GovTokenUnregistered');
    const govTokenLength2 = await govTokenRegistry.callStatic.getGovTokensLength();
    expect(govTokenLength2).to.eq(3);

    console.log('\n>>> harvest #3 after another 1 days');
    await ethers.provider.send('evm_increaseTime', [60 * 60 * 24]);
    const harvestTx3 = await strategy.harvest({ gasLimit: 2000000 });
    const receipt3 = await harvestTx3.wait();
    console.log('---- gas used =', receipt3.gasUsed.toString());
    const price7 = await strategy.callStatic.syncPrice();
    const shares7 = await strategy.shares();
    const assetAmount7 = price7.mul(shares7).div(BigNumber.from(10).pow(18));
    console.log('---- shares =', shares7.toString());
    console.log('---- price =', price7.toString());
    console.log('---- assetAmount =', assetAmount7.toString());
    expect(shares7).to.eq(shares6);
    expect(assetAmount7).to.gte(assetAmount6);
}
