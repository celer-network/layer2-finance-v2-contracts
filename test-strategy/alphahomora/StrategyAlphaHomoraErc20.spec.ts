import { expect } from 'chai';
import { ethers, network } from 'hardhat';

import { getAddress } from '@ethersproject/address';
import { parseEther, parseUnits } from '@ethersproject/units';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

import { ERC20 } from '../../typechain/ERC20.d';
import { ERC20__factory } from '../../typechain/factories/ERC20__factory';
import { StrategyAlphaHomoraErc20__factory } from '../../typechain/factories/StrategyAlphaHomoraErc20__factory';
import { StrategyAlphaHomoraErc20 } from '../../typechain/StrategyAlphaHomoraErc20';
import { ensureBalanceAndApproval, getDeployerSigner } from '../common';

interface DeployStrategyAlphaHomoraErc20Info {
  strategy: StrategyAlphaHomoraErc20;
  supplyToken: ERC20;
  deployerSigner: SignerWithAddress;
}

async function deployStrategyAlphaHomoraErc20(
  deployedAddress: string | undefined,
  supplyTokenAddress: string,
  ibTokenAddress: string
): Promise<DeployStrategyAlphaHomoraErc20Info> {
  const deployerSigner = await getDeployerSigner();
  let strategy: StrategyAlphaHomoraErc20;
  if (deployedAddress) {
    strategy = StrategyAlphaHomoraErc20__factory.connect(deployedAddress, deployerSigner);
  } else {
    const StrategyAlphaHomoraErc20Factory = (await ethers.getContractFactory(
      'StrategyAlphaHomoraErc20'
    )) as StrategyAlphaHomoraErc20__factory;
    strategy = await StrategyAlphaHomoraErc20Factory
      .connect(deployerSigner)
      .deploy(
        ibTokenAddress,
        supplyTokenAddress,
        deployerSigner.address
      );
    await strategy.deployed();
  }

  const supplyToken = ERC20__factory.connect(supplyTokenAddress, deployerSigner);

  return { strategy, supplyToken, deployerSigner };
}

export async function testStrategyAlphaHomoraErc20(
    context: Mocha.Context,
    deployedAddress: string | undefined,
    supplyTokenAddress: string,
    ibTokenAddress: string,
    supplyTokenFunder: string,
    supplyTokenDecimals: number,
    supplyTokenSymbol: string
  ): Promise<void> {
    context.timeout(300000);
  
    const { strategy, supplyToken, deployerSigner } = await deployStrategyAlphaHomoraErc20(
      deployedAddress,
      supplyTokenAddress,
      ibTokenAddress
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
  }