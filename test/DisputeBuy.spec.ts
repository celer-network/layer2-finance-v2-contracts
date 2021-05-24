import { expect } from 'chai';

import { keccak256 as solidityKeccak256 } from '@ethersproject/solidity';
import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeBuySell', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(10);

    return {
      admin,
      rollupChain,
      celr,
      dai
    };
  }
/*
  it('should fail to dispute valid buy', async function () {
    const { admin, rollupChain, dai } = await loadFixture(fixture);
    const users = await getUsers(admin, [dai], 1);
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(dai.address, parseEther('1'));

    const { tns, disputeData } = await parseInput('test/input/data/dispute-buy-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });
*/
  it('should dispute buy with invalid rooot', async function () {
    const { admin, rollupChain, dai } = await loadFixture(fixture);
    const users = await getUsers(admin, [dai], 1);
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(dai.address, parseEther('1'));

    const { tns, disputeData } = await parseInput('test/input/data/dispute-buy-root.txt');

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
