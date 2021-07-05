import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { advanceBlockNumberTo, deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeStakingRewardTwoUsers', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai, weth } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(5);

    const users = await getUsers(admin, [celr, dai], 2);
    const depositAmount = parseEther('100');
    const rewardAmount = parseEther('200');
    await dai.approve(rollupChain.address, depositAmount);
    await weth.deposit({ value: rewardAmount });
    await weth.approve(rollupChain.address, rewardAmount);
    await rollupChain.depositReward(weth.address, rewardAmount);
    await dai.connect(users[0]).approve(rollupChain.address, depositAmount);
    await rollupChain.connect(users[0]).deposit(dai.address, depositAmount);
    await dai.connect(users[1]).approve(rollupChain.address, depositAmount);
    await rollupChain.connect(users[1]).deposit(dai.address, depositAmount);

    return {
      admin,
      rollupChain,
      celr,
      dai,
      users
    };
  }

  it('should fail to dispute valid staking reward, two users, user 1', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-staking-reward-two-users-valid-1.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(50 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][6]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(100 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should fail to dispute valid staking reward, two users, user 2', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-staking-reward-two-users-valid-2.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(200 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][6]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(250 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute incorrect staking reward, two users, user 1', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-staking-reward-two-users-amt-1.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(350 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][6]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(400 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(2, 'failed to evaluate');
  });

  it('should dispute incorrect staking reward, two users, user 2', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-staking-reward-two-users-amt-2.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(500 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][6]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(550 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(2, 'failed to evaluate');
  });
});
