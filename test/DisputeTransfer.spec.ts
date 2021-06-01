import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { advanceBlockNumberTo, deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeTransfer', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, dai } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(10);

    const users = await getUsers(admin, [dai], 2);
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await dai.connect(users[1]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(dai.address, parseEther('100'));
    await rollupChain.connect(users[1]).deposit(dai.address, parseEther('100'));

    return {
      admin,
      rollupChain
    };
  }

  it('should fail to dispute valid share transfer', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-transfer-share-valid.txt');

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

  it('should dispute share transfer with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-transfer-share-root.txt');

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

  it('should dispute share transfer with invalid amount', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-transfer-share-amt.txt');

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

  it('should fail to dispute valid asset transfer', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-transfer-asset-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute asset transfer with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-transfer-asset-root.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(0, 'invalid post-state root');
  });

  it('should dispute asset transfer with invalid amount', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-transfer-asset-amt.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(0, 'failed to evaluate');
  });

  it('should dispute asset transfer with invalid asset id', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-transfer-asset-id.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(0, 'failed to evaluate');
  });

  it('should fail to dispute valid asset transfer to a new account', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-transfer-asset-new-acnt-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute asset transfer with invalid signature', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-transfer-asset-sig.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(0, 'failed to evaluate');
  });
});
