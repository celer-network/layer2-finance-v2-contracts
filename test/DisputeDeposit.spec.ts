import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeDeposit', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(5);

    return {
      admin,
      rollupChain,
      celr,
      dai
    };
  }

  it('should fail to dispute valid deposit', async function () {
    const { admin, rollupChain, celr, dai } = await loadFixture(fixture);
    const users = await getUsers(admin, [celr, dai], 1);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await rollupChain.connect(users[0]).deposit(celr.address, 100);
    await rollupChain.connect(users[0]).deposit(dai.address, 100);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-deposit-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute deposit with invalid root', async function () {
    const { admin, rollupChain, celr, dai } = await loadFixture(fixture);
    const users = await getUsers(admin, [celr, dai], 1);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await rollupChain.connect(users[0]).deposit(celr.address, 100);
    await rollupChain.connect(users[0]).deposit(dai.address, 100);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-deposit-root.txt');

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

  it('should dispute new account deposit with invalid root', async function () {
    const { admin, rollupChain, celr, dai } = await loadFixture(fixture);
    const users = await getUsers(admin, [celr, dai], 2);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await dai.connect(users[1]).approve(rollupChain.address, parseEther('1'));
    await rollupChain.connect(users[0]).deposit(celr.address, 100);
    await rollupChain.connect(users[1]).deposit(dai.address, 100);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-deposit-create.txt');

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

  it('should dispute deposit with invalid account id', async function () {
    const { admin, rollupChain, celr, dai } = await loadFixture(fixture);
    const users = await getUsers(admin, [celr, dai], 1);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await rollupChain.connect(users[0]).deposit(celr.address, 100);
    await rollupChain.connect(users[0]).deposit(dai.address, 100);

    const { tns, disputeData } = await parseInput('test/input/data/dispute-deposit-acntid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(0, 'invalid account id');
  });
});
