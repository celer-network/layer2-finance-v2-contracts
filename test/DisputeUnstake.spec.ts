import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { advanceBlockNumberTo, deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeUnstake', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(5);

    const users = await getUsers(admin, [celr, dai], 2);
    const depositAmount = parseEther('100');
    await celr.approve(rollupChain.address, depositAmount);
    await rollupChain.depositReward(celr.address, depositAmount);
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

  it('should fail to dispute valid unstake', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-unstake-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(50 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute unstake with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-unstake-root.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(100 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(1, 'invalid post-state root');
  });

  it('should dispute unstake with invalid shares', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-unstake-shares.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(150 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(1, 'failed to evaluate');
  });

  it('should fail to dispute valid unstake with share fee', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-unstake-fee-share-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(200 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute unstake with share fee with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-unstake-fee-share-root.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(250 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(1, 'invalid post-state root');
  });

  it('should dispute unstake with invalid share fee amt', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-unstake-fee-share-amt.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(300 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(1, 'failed to evaluate');
  });

  it('should fail to dispute valid unstake with celr fee', async function () {
    const { admin, rollupChain, celr, users } = await loadFixture(fixture);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(celr.address, parseEther('0.5'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-unstake-fee-celr-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(400 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][5]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute unstake with celr fee with invalid root', async function () {
    const { admin, rollupChain, celr, users } = await loadFixture(fixture);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(celr.address, parseEther('0.5'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-unstake-fee-celr-root.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(500 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][5]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(1, 'invalid post-state root');
  });

  it('should dispute unstake with invalid celr fee amt', async function () {
    const { admin, rollupChain, celr, users } = await loadFixture(fixture);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(celr.address, parseEther('0.5'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-unstake-fee-celr-amt.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(600 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][5]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(1, 'failed to evaluate');
  });
});
