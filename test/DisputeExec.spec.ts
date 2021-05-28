import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { advanceBlockNumberTo, deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeExecResult', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(10);

    const users = await getUsers(admin, [dai], 2);
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await dai.connect(users[1]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(dai.address, parseEther('100'));
    await rollupChain.connect(users[1]).deposit(dai.address, parseEther('100'));

    return {
      admin,
      rollupChain,
      celr,
      dai
    };
  }

  it('should fail to dispute valid execute result', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-exec-valid.txt');

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

  it('should dispute execute result with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-exec-root.txt');

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
});
