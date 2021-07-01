import { expect } from 'chai';
import { ethers } from 'hardhat';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { advanceBlockNumberTo, deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('Staking', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai } = await deployContracts(admin);

    return {
      admin,
      rollupChain,
      celr,
      dai
    };
  }

  it('should aggregate staking tns correctly', async function () {
    const { admin, rollupChain, dai } = await loadFixture(fixture);
    const users = await getUsers(admin, [dai], 2);
    const depositAmount = parseEther('100');
    await dai.approve(rollupChain.address, depositAmount);
    expect(rollupChain.depositReward(dai.address, depositAmount))
      .to.emit(rollupChain, 'AssetDeposited')
      .withArgs(ethers.constants.AddressZero, 2, depositAmount, 0);

    await dai.connect(users[0]).approve(rollupChain.address, depositAmount);
    await rollupChain.connect(users[0]).deposit(dai.address, depositAmount);

    const { tns } = await parseInput('test/input/data/staking.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(50 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    // NOTE: Enable to get aggregation epoch
    // const aggr = await rollupChain.queryFilter(
    //   rollupChain.filters.AggregationExecuted(null, null, null, null, null, null),
    //   -1
    // );
    // console.log("Aggregation epoch:", aggr[0].args.currEpoch.toString());

    await rollupChain.commitBlock(1, tns[1]);
    await rollupChain.executeBlock(1, [], 0);
  });
});
