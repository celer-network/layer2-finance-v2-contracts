import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { advanceBlockNumberTo, deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeEpoch', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(5);

    return {
      admin,
      rollupChain,
      celr
    };
  }

  it('should fail to dispute valid epoch update', async function () {
    const { admin, rollupChain, celr } = await loadFixture(fixture);
    const users = await getUsers(admin, [celr], 1);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await rollupChain.connect(users[0]).deposit(celr.address, 100);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-epoch-valid.txt');

    await advanceBlockNumberTo(50 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should fail to dispute epoch update with invalid root', async function () {
    const { admin, rollupChain, celr } = await loadFixture(fixture);
    const users = await getUsers(admin, [celr], 1);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await rollupChain.connect(users[0]).deposit(celr.address, 100);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-epoch-root.txt');

    await advanceBlockNumberTo(100 - 1);
    await rollupChain.updateEpoch();
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

  it('should fail when update incorrect epoch', async function () {
    const { admin, rollupChain, celr } = await loadFixture(fixture);
    const users = await getUsers(admin, [celr], 1);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await rollupChain.connect(users[0]).deposit(celr.address, 100);

    const { tns } = await parseInput('test/input/data/dispute-epoch-valid.txt');

    await rollupChain.updateEpoch();
    await expect(rollupChain.commitBlock(0, tns[0])).to.be.revertedWith('invalid epoch');
  });
});
