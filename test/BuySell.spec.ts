import { expect } from 'chai';
import { ethers } from 'hardhat';

import { keccak256 as solidityKeccak256 } from '@ethersproject/solidity';
import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('BuySell', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai } = await deployContracts(admin);

    return {
      admin,
      rollupChain,
      celr,
      dai
    };
  }

  it('should aggregate orders correctly', async function () {
    const { admin, rollupChain, dai } = await loadFixture(fixture);
    const users = await getUsers(admin, [dai], 2);
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await dai.connect(users[1]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(dai.address, parseEther('100'));
    await rollupChain.connect(users[1]).deposit(dai.address, parseEther('100'));

    const { tns } = await parseInput('test/input/data/buy-sell.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await expect(rollupChain.executeBlock(0, [tns[0][4]], 1))
      .to.emit(rollupChain, 'AggregationExecuted')
      .withArgs(1, 0, true, parseEther('5'), 0, 35);

    let [ehash, blockId, status] = await rollupChain.pendingExecResults(1, 0);
    let h = solidityKeccak256(
      ['uint32', 'uint64', 'bool', 'uint256', 'uint256', 'uint64'],
      [1, 0, true, parseEther('5'), 0, 35]
    );
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    await rollupChain.commitBlock(1, tns[1]);

    [, , status] = await rollupChain.pendingExecResults(1, 0);
    expect(status).to.equal(1);

    await expect(rollupChain.executeBlock(1, [tns[1][5]], 1))
      .to.emit(rollupChain, 'AggregationExecuted')
      .withArgs(1, 1, true, 0, parseEther('2'), 37);

    [ehash, blockId, status] = await rollupChain.pendingExecResults(1, 0);
    expect(ehash).to.equal('0x0000000000000000000000000000000000000000000000000000000000000000');
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    await rollupChain.commitBlock(2, tns[2]);

    [, , status] = await rollupChain.pendingExecResults(1, 1);
    expect(status).to.equal(1);
  });
});
