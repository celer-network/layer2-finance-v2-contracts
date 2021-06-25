import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { advanceBlockNumberTo, deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeStake', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(10);

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

  it('should fail to dispute valid stake', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-stake-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(50 - 1);
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute stake with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-stake-root.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(100 - 1);
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

  it('should dispute stake with invalid shares', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-stake-shares.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(150 - 1);
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

  it('should fail to dispute valid stake with share fee', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-stake-fee-share-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(200 - 1);
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute stake with share fee with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-stake-fee-share-root.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(250 - 1);
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

  it('should dispute stake with invalid share fee amt', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-stake-fee-share-amt.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(300 - 1);
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

  it('should fail to dispute valid stake with celr fee', async function () {
    const { admin, rollupChain, celr, users } = await loadFixture(fixture);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(celr.address, parseEther('0.5'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-stake-fee-celr-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(400 - 1);
    await rollupChain.executeBlock(0, [tns[0][5]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute stake with celr fee with invalid root', async function () {
    const { admin, rollupChain, celr, users } = await loadFixture(fixture);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(celr.address, parseEther('0.5'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-stake-fee-celr-root.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(500 - 1);
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

  it('should dispute stake with invalid celr fee amt', async function () {
    const { admin, rollupChain, celr, users } = await loadFixture(fixture);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(celr.address, parseEther('0.5'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-stake-fee-celr-amt.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(600 - 1);
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
