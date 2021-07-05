import { expect } from 'chai';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { advanceBlockNumberTo, deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DisputeStakingReward', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, celr, dai, weth } = await deployContracts(admin);
    await rollupChain.setBlockChallengePeriod(5);

    const users = await getUsers(admin, [celr, dai], 2);
    const depositAmount = parseEther('100');
    const rewardAmount = parseEther('200');
    await dai.approve(rollupChain.address, depositAmount);
    await weth.deposit({ value: rewardAmount });
    await weth.approve(rollupChain.address, rewardAmount);
    await rollupChain.depositReward(weth.address, rewardAmount);
    await dai.connect(users[0]).approve(rollupChain.address, depositAmount);
    await rollupChain.connect(users[0]).deposit(dai.address, depositAmount);

    return {
      admin,
      rollupChain,
      celr,
      dai,
      users
    };
  }

  it('should fail to dispute valid staking reward', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-staking-reward-valid.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(50 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(100 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute incorrect staking reward', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput('test/input/data/dispute-staking-reward-amt.txt');

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(200 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(250 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(2, 'failed to evaluate');
  });

  it('should fail to dispute valid staking reward, UpdatePool-StartEpoch-Stake', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-updatepool-startepoch-stake-valid.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(350 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][5]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(400 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute incorrect staking reward, UpdatePool-StartEpoch-Stake', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-updatepool-startepoch-stake-amt.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(500 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][5]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(550 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(2, 'failed to evaluate');
  });

  it('should fail to dispute valid staking reward, StartEpoch-UpdatePool-Stake', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-startepoch-updatepool-stake-valid.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(650 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(700 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute incorrect staking reward, StartEpoch-UpdatePool-Stake', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-startepoch-updatepool-stake-amt.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(800 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(850 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(2, 'failed to evaluate');
  });

  it('should fail to dispute valid staking reward, StartEpoch-Stake-UpdatePool', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-startepoch-stake-updatepool-valid.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(950 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(1000 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await advanceBlockNumberTo(1050 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(3, tns[3]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute incorrect staking reward, StartEpoch-Stake-UpdatePool', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-startepoch-stake-updatepool-amt.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(1150 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(1200 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await advanceBlockNumberTo(1250 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(3, tns[3]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(3, 'failed to evaluate');
  });

  it('should fail to dispute valid staking reward, UpdatePool-Stake-StartEpoch', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-updatepool-stake-startepoch-valid.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(1350 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][5]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(1450 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute incorrect staking reward, UpdatePool-Stake-StartEpoch', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-updatepool-stake-startepoch-amt.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(1550 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][5]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(1650 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(2, 'failed to evaluate');
  });

  it('should fail to dispute valid staking reward, Stake-UpdatePool-StartEpoch', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-stake-updatepool-startepoch-valid.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(1750 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(1800 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await advanceBlockNumberTo(1900 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(3, tns[3]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should dispute incorrect staking reward, Stake-UpdatePool-StartEpoch', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-stake-updatepool-startepoch-amt.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(2000 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(2050 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await advanceBlockNumberTo(2150 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(3, tns[3]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(3, 'failed to evaluate');
  });

  it('should fail to dispute valid staking reward, Stake-StartEpoch-UpdatePool', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-stake-startepoch-updatepool-valid.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(2250 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(2350 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await advanceBlockNumberTo(2400 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(3, tns[3]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    ).to.be.revertedWith('Failed to dispute');
  });

  it('should fail to dispute valid staking reward, Stake-StartEpoch-UpdatePool', async function () {
    const { admin, rollupChain } = await loadFixture(fixture);
    const { tns, disputeData } = await parseInput(
      'test/input/data/dispute-staking-reward-stake-startepoch-updatepool-amt.txt'
    );

    await rollupChain.commitBlock(0, tns[0]);
    await advanceBlockNumberTo(2500 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.executeBlock(0, [tns[0][4]], 1);
    await rollupChain.commitBlock(1, tns[1]);
    await advanceBlockNumberTo(2600 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(2, tns[2]);
    await advanceBlockNumberTo(2650 - 1);
    await rollupChain.updateEpoch();
    await rollupChain.commitBlock(3, tns[3]);
    await expect(
      admin.sendTransaction({
        to: rollupChain.address,
        data: disputeData
      })
    )
      .to.emit(rollupChain, 'RollupBlockReverted')
      .withArgs(3, 'failed to evaluate');
  });
});
