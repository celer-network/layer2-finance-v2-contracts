import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { advanceBlockNumberTo, deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeSettle', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(10);

    const users = await getUsers(admin, [celr, dai], 2);
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(dai.address, parseEther('100'));

    return {
      admin,
      rollupChain,
      celr,
      dai,
      users
    };
  }

  it('should fail to dispute valid settle', async function () {
    const { admin, rollupChain, dai, users } = await loadFixture(fixture);
    await dai.connect(users[1]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[1]).deposit(dai.address, parseEther('100'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(50 - 1);
    await rollupChain.executeBlock(0, [tns[0][4]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(100 - 1);
    await rollupChain.executeBlock(1, [tns[1][8]], 1);

    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute settle with invalid root', async function () {
    const { admin, rollupChain, dai, users } = await loadFixture(fixture);
    await dai.connect(users[1]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[1]).deposit(dai.address, parseEther('100'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-root.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(150 - 1);
    await rollupChain.executeBlock(0, [tns[0][4]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(200 - 1);
    await rollupChain.executeBlock(1, [tns[1][8]], 1);

    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(2, 'invalid post-state root');
  });

  it('should fail to dispute valid settle with asset fee', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-fee-asset-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(250 - 1);
    await rollupChain.executeBlock(0, [tns[0][2]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(300 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);

    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should fail to dispute valid settle with asset fee that exceeds amt from sell', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-fee-asset-valid2.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(350 - 1);
    await rollupChain.executeBlock(0, [tns[0][2]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(400 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);

    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute valid settle with asset fee with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-fee-asset-root.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(450 - 1);
    await rollupChain.executeBlock(0, [tns[0][2]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(500 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);

    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(2, 'invalid post-state root');
  });

  it('should fail to dispute valid settle with celr fee', async function () {
    const { admin, rollupChain, celr, users } = await loadFixture(fixture);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(celr.address, parseEther('0.5'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-fee-celr-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(550 - 1);
    await rollupChain.executeBlock(0, [tns[0][3]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(600 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);

    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute valid settle with celr fee with invalid root', async function () {
    const { admin, rollupChain, celr, users } = await loadFixture(fixture);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(celr.address, parseEther('0.5'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-fee-celr-root.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(650 - 1);
    await rollupChain.executeBlock(0, [tns[0][3]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(700 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);

    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(2, 'invalid post-state root');
  });

  it('should fail to dispute valid settle with asset refund', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-refund-asset-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(750 - 1);
    await rollupChain.executeBlock(0, [tns[0][2]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(800 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);

    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute valid settle with asset refund with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-refund-asset-root.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(850 - 1);
    await rollupChain.executeBlock(0, [tns[0][2]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(900 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);

    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(2, 'invalid post-state root');
  });

  it('should dispute valid settle with asset refund with invalid amt', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-refund-asset-amt.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(950 - 1);
    await rollupChain.executeBlock(0, [tns[0][2]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(1000 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);

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

  it('should fail to dispute valid settle with celr refund', async function () {
    const { admin, rollupChain, celr, users } = await loadFixture(fixture);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(celr.address, parseEther('0.5'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-refund-celr-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(1050 - 1);
    await rollupChain.executeBlock(0, [tns[0][3]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(1100 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);

    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute valid settle with celr refund with invalid root', async function () {
    const { admin, rollupChain, celr, users } = await loadFixture(fixture);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(celr.address, parseEther('0.5'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-refund-celr-root.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(1150 - 1);
    await rollupChain.executeBlock(0, [tns[0][3]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(1200 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);

    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(2, 'invalid post-state root');
  });

  it('should dispute valid settle with celr refund with invalid amt', async function () {
    const { admin, rollupChain, celr, users } = await loadFixture(fixture);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(celr.address, parseEther('0.5'));
    const { tns, disputeData } = await parseInput('test/input/data/dispute-settle-refund-celr-amt.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await advanceBlockNumberTo(1250 - 1);
    await rollupChain.executeBlock(0, [tns[0][3]], 1);

    await rollupChain.commitBlock(1, tns[1]);

    await advanceBlockNumberTo(1300 - 1);
    await rollupChain.executeBlock(1, [tns[1][4]], 1);

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
