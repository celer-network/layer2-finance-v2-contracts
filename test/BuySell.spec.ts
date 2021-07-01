import { expect } from 'chai';

import { keccak256 as solidityKeccak256 } from '@ethersproject/solidity';
import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('BuySell', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, priorityQueues, dai, weth } = await deployContracts(admin);

    return {
      admin,
      rollupChain,
      priorityQueues,
      dai,
      weth
    };
  }

  it('should aggregate orders correctly', async function () {
    const { admin, rollupChain, priorityQueues, dai } = await loadFixture(fixture);
    const users = await getUsers(admin, [dai], 2);
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await dai.connect(users[1]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(dai.address, parseEther('100'));
    await rollupChain.connect(users[1]).deposit(dai.address, parseEther('100'));

    const { tns } = await parseInput('test/input/data/buy-sell.txt');

    await rollupChain.commitBlock(0, tns[0]);

    await expect(rollupChain.executeBlock(0, [tns[0][4]], 1))
      .to.emit(rollupChain, 'AggregationExecuted')
      .withArgs(1, 0, true, parseEther('5'), 0);

    let [ehash, blockId, status] = await priorityQueues.pendingExecResults(1, 0);
    const h = solidityKeccak256(['uint32', 'uint64', 'bool', 'uint256', 'uint256'], [1, 0, true, parseEther('5'), 0]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    await rollupChain.commitBlock(1, tns[1]);

    [, , status] = await priorityQueues.pendingExecResults(1, 0);
    expect(status).to.equal(1);

    await expect(rollupChain.executeBlock(1, [tns[1][8]], 1))
      .to.emit(rollupChain, 'AggregationExecuted')
      .withArgs(1, 1, true, parseEther('3'), parseEther('2.5'));

    [ehash, blockId, status] = await priorityQueues.pendingExecResults(1, 0);
    expect(ehash).to.equal('0x0000000000000000000000000000000000000000000000000000000000000000');
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    await rollupChain.commitBlock(2, tns[2]);

    [, , status] = await priorityQueues.pendingExecResults(1, 1);
    expect(status).to.equal(1);
  });

  it('should execute orders one-by-one correctly', async function () {
    const { admin, rollupChain, dai, weth } = await loadFixture(fixture);
    const users = await getUsers(admin, [dai], 3);
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await dai.connect(users[1]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(dai.address, parseEther('100'));
    await rollupChain.connect(users[1]).deposit(dai.address, parseEther('100'));
    await rollupChain.connect(users[2]).depositETH(weth.address, parseEther('1'), { value: parseEther('1') });

    const { tns } = await parseInput('test/input/data/execute-orders.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await rollupChain.commitBlock(1, tns[1]);

    const intents = [tns[0][6], tns[0][7], tns[0][8]];
    await expect(rollupChain.executeBlock(0, intents, 1))
      .to.emit(rollupChain, 'AggregationExecuted')
      .withArgs(1, 0, true, parseEther('3'), 0)
      .to.emit(rollupChain, 'RollupBlockExecuted')
      .withArgs(0, 1);

    await expect(rollupChain.executeBlock(0, intents, 1))
      .to.emit(rollupChain, 'AggregationExecuted')
      .withArgs(2, 0, true, parseEther('2'), 0)
      .to.emit(rollupChain, 'RollupBlockExecuted')
      .withArgs(0, 2);

    await expect(rollupChain.executeBlock(1, [tns[1][1]], 1)).to.be.revertedWith('invalid block ID');

    await expect(rollupChain.executeBlock(0, intents, 1))
      .to.emit(rollupChain, 'AggregationExecuted')
      .withArgs(3, 0, true, parseEther('1'), 0)
      .to.emit(rollupChain, 'RollupBlockExecuted')
      .withArgs(0, 3);

    await expect(rollupChain.executeBlock(1, [tns[1][1]], 1))
      .to.emit(rollupChain, 'AggregationExecuted')
      .withArgs(1, 1, true, parseEther('5'), 0)
      .to.emit(rollupChain, 'RollupBlockExecuted')
      .withArgs(1, 1);
  });

  it('should execute orders in batch correctly', async function () {
    const { admin, rollupChain, dai, weth } = await loadFixture(fixture);
    const users = await getUsers(admin, [dai], 3);
    await dai.connect(users[0]).approve(rollupChain.address, parseEther('100'));
    await dai.connect(users[1]).approve(rollupChain.address, parseEther('100'));
    await rollupChain.connect(users[0]).deposit(dai.address, parseEther('100'));
    await rollupChain.connect(users[1]).deposit(dai.address, parseEther('100'));
    await rollupChain.connect(users[2]).depositETH(weth.address, parseEther('1'), { value: parseEther('1') });

    const { tns } = await parseInput('test/input/data/execute-orders.txt');

    await rollupChain.commitBlock(0, tns[0]);

    const intents = [tns[0][6], tns[0][7], tns[0][8]];
    await expect(rollupChain.executeBlock(0, intents, 2))
      .to.emit(rollupChain, 'AggregationExecuted')
      .withArgs(1, 0, true, parseEther('3'), 0)
      .to.emit(rollupChain, 'AggregationExecuted')
      .withArgs(2, 0, true, parseEther('2'), 0)
      .to.emit(rollupChain, 'RollupBlockExecuted')
      .withArgs(0, 2);

    let [, , intentExecCount, , ,] = await rollupChain.blocks(0);
    expect(intentExecCount).to.equal(2);

    await expect(rollupChain.executeBlock(0, intents, 2)).to.be.revertedWith('invalid data length');

    await expect(rollupChain.executeBlock(0, intents, 1))
      .to.emit(rollupChain, 'AggregationExecuted')
      .withArgs(3, 0, true, parseEther('1'), 0)
      .to.emit(rollupChain, 'RollupBlockExecuted')
      .withArgs(0, 3);

    [, , intentExecCount, , ,] = await rollupChain.blocks(0);
    expect(intentExecCount).to.equal(2 ** 32 - 1);
  });
});
