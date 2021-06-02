import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeFee', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, dai } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(10);

    const users = await getUsers(admin, [dai], 1);
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(dai.address, parseEther('100'));

    return {
      admin,
      rollupChain,
      users
    };
  }

  it('should fail to dispute valid protocol fee withdrawal', async function () {
    const { admin, rollupChain, users } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-fee-withdraw-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    let [account, assetId, amount] = await rollupChain.pendingWithdrawCommits(0, 0);
    expect(account).to.equal(users[0].address);
    expect(assetId).to.equal(2);
    expect(amount).to.equal(parseEther('0.9'));

    [account, assetId, amount] = await rollupChain.pendingWithdrawCommits(0, 1);
    expect(account).to.equal(admin.address);
    expect(assetId).to.equal(2);
    expect(amount).to.equal(parseEther('0.1'));

    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute protocol fee withdrawal with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-fee-withdraw-root.txt');

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

  it('should dispute protocol fee withdrawal with invalid amount', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-fee-withdraw-amt.txt');

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

  it('should fail to dispute valid operation fee transfer', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-fee-transfer-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute operation fee transfer with invalid root', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-fee-transfer-root.txt');

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

  it('should dispute operation fee transfer with invalid destination account', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-fee-transfer-acnt.txt');

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
