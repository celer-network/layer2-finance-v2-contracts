import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeInitTn', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(5);

    return {
      admin,
      rollupChain,
      celr
    };
  }

  it('should fail to dispute valid init tn', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-init-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute init tn with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-init-root.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(0, 'invalid init tn');
  });

  it('should fail to dispute valid deposit after init tn', async function () {
    const { admin, rollupChain, celr } = await loadFixture(fixture);
    const users = await getUsers(admin, [celr], 1);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await rollupChain.connect(users[0]).deposit(celr.address, 100);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-init-deposit-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute deposit with invalid root after init tn', async function () {
    const { admin, rollupChain, celr } = await loadFixture(fixture);
    const users = await getUsers(admin, [celr], 1);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await rollupChain.connect(users[0]).deposit(celr.address, 100);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-init-deposit-root.txt');

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
});
