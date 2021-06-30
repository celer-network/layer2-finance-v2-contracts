import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { advanceBlockNumberTo, deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeUnstakeTwice', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai, weth } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(10);

    const users = await getUsers(admin, [celr, dai], 2);
    const depositAmount = parseEther('100');
    await dai.approve(rollupChain.address, depositAmount);
    await weth.deposit({ value: depositAmount });
    await weth.approve(rollupChain.address, depositAmount);
    await rollupChain.depositReward(weth.address, depositAmount);
    await dai.connect(users[0]).approve(rollupChain.address, depositAmount);
    await rollupChain.connect(users[0]).deposit(dai.address, depositAmount);

    return {
      admin,
      rollupChain,
      celr,
      dai,
      users
    };
  }

  it('should fail to dispute valid second unstake', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-unstake-twice-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(50 - 1);
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(157 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });
});
