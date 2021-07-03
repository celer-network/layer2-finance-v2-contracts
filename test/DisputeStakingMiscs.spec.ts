import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { deployContracts, loadFixture, parseInput } from './common';

describe('DisputeStakingMiscs', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(5);

    const depositAmount = parseEther('100');
    await celr.approve(rollupChain.address, depositAmount);
    await rollupChain.depositReward(celr.address, depositAmount);

    return {
      admin,
      rollupChain,
      celr
    };
  }

  it('should fail to dispute valid DepositReward', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-depositreward-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute DepositReward with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-depositreward-root.txt');

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

  it('should fail to dispute valid AddPool', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-addpool-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute AddPool with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-addpool-root.txt');

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

  it('should fail to dispute valid UpdatePool', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-updatepool-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute UpdatePool with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-updatepool-root.txt');

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
