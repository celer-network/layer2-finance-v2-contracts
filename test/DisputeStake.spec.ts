import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { advanceBlockNumberTo, deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeStake', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(10);

    const users = await getUsers(admin, [dai], 2);
    const depositAmount = parseEther('100');
    await dai.approve(rollupChain.address, depositAmount);
    await rollupChain.depositReward(dai.address, depositAmount);
    await dai.connect(users[0]).approve(rollupChain.address, depositAmount);
    await rollupChain.connect(users[0]).deposit(dai.address, depositAmount);

    return {
      admin,
      rollupChain,
      celr,
      dai
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
});
