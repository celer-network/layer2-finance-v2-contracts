import { expect } from 'chai';
import { ethers } from 'hardhat';

import { BigNumber } from '@ethersproject/bignumber';
import { keccak256 as solidityKeccak256 } from '@ethersproject/solidity';
import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DepositWithdraw', function () {
  async function fixture([admin]: Wallet[]) {
    const { rollupChain, priorityOperations, celr, weth } = await deployContracts(admin);

    return {
      admin,
      rollupChain,
      priorityOperations,
      celr,
      weth
    };
  }

  it('should deposit and withdraw ERC20 and ETH', async function () {
    const { admin, rollupChain, priorityOperations, celr, weth } = await loadFixture(fixture);
    const users = await getUsers(admin, [celr], 1);
    const depositAmount = 100;
    const withdrawAmount = 50;
    const { tns } = await parseInput('test/input/data/deposit-withdraw.txt');

    // ERC20
    await celr.connect(users[0]).approve(rollupChain.address, depositAmount);
    await expect(rollupChain.connect(users[0]).deposit(celr.address, depositAmount))
      .to.emit(rollupChain, 'AssetDeposited')
      .withArgs(users[0].address, 1, depositAmount, 0);

    let [ehash, blockId, status] = await priorityOperations.pendingDeposits(0);
    let h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[0].address, 1, depositAmount]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    await expect(rollupChain.connect(users[0]).withdraw(users[0].address, celr.address)).to.be.revertedWith(
      'invalid amount'
    );

    await rollupChain.commitBlock(0, tns[0]);

    let [account, assetId, amount] = await rollupChain.pendingWithdrawCommits(0, 0);
    expect(account).to.equal(users[0].address);
    expect(assetId).to.equal(1);
    expect(amount).to.equal(withdrawAmount);

    await rollupChain.executeBlock(0, [], 0);

    let totalAmount = await rollupChain.pendingWithdraws(users[0].address, assetId);
    expect(assetId).to.equal(1);
    expect(totalAmount).to.equal(withdrawAmount);

    let balanceBefore = await celr.balanceOf(users[0].address);
    await rollupChain.withdraw(users[0].address, celr.address);
    let balanceAfter = await celr.balanceOf(users[0].address);
    expect(balanceAfter.sub(balanceBefore)).to.equal(withdrawAmount);

    // ETH
    await expect(
      rollupChain.connect(users[0]).depositETH(weth.address, depositAmount, {
        value: depositAmount
      })
    )
      .to.emit(rollupChain, 'AssetDeposited')
      .withArgs(users[0].address, 3, depositAmount, 1);

    [ehash, blockId, status] = await priorityOperations.pendingDeposits(1);
    h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[0].address, 3, depositAmount]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(1);
    expect(status).to.equal(0);

    await rollupChain.commitBlock(1, tns[1]);

    [account, assetId, amount] = await rollupChain.pendingWithdrawCommits(1, 0);
    expect(account).to.equal(users[0].address);
    expect(assetId).to.equal(3);
    expect(amount).to.equal(withdrawAmount);

    await rollupChain.executeBlock(1, [], 0);

    totalAmount = await rollupChain.pendingWithdraws(users[0].address, assetId);
    expect(assetId).to.equal(3);
    expect(totalAmount).to.equal(withdrawAmount);

    balanceBefore = await ethers.provider.getBalance(users[0].address);
    const withdrawTx = await rollupChain.connect(users[0]).withdrawETH(users[0].address, weth.address);
    const receipt = await withdrawTx.wait();
    const gasSpent = receipt.gasUsed.mul(receipt.effectiveGasPrice);
    balanceAfter = await ethers.provider.getBalance(users[0].address);
    expect(balanceAfter.sub(balanceBefore).add(gasSpent)).to.equal(withdrawAmount);
  });

  it('should handle deposit transition queue correctly', async function () {
    const { admin, rollupChain, priorityOperations, celr, weth } = await loadFixture(fixture);

    const users = await getUsers(admin, [celr], 2);
    await celr.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await celr.connect(users[1]).approve(rollupChain.address, parseEther('1'));
    await rollupChain.connect(users[0]).deposit(celr.address, 100);
    await rollupChain.connect(users[1]).depositETH(weth.address, 200, { value: 200 });
    await rollupChain.connect(users[1]).deposit(celr.address, 300);
    await rollupChain.connect(users[0]).depositETH(weth.address, 400, { value: 400 });

    let [ehash, blockId, status] = await priorityOperations.pendingDeposits(0);
    let h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[0].address, 1, 100]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    [ehash, blockId, status] = await priorityOperations.pendingDeposits(1);
    h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[1].address, 3, 200]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    [ehash, blockId, status] = await priorityOperations.pendingDeposits(2);
    h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[1].address, 1, 300]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    [ehash, blockId, status] = await priorityOperations.pendingDeposits(3);
    h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[0].address, 3, 400]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    const { tns } = await parseInput('test/input/data/deposit-queue.txt');

    await expect(rollupChain.commitBlock(0, tns[1])).to.be.revertedWith('invalid data hash');
    await rollupChain.commitBlock(0, tns[0]);

    [, , status] = await priorityOperations.pendingDeposits(2);
    expect(status).to.equal(1);
    [, , status] = await priorityOperations.pendingDeposits(3);
    expect(status).to.equal(0);

    await rollupChain.commitBlock(1, tns[1]);
    [, , status] = await priorityOperations.pendingDeposits(3);
    expect(status).to.equal(1);

    await expect(rollupChain.executeBlock(0, [], 0)).to.emit(rollupChain, 'RollupBlockExecuted').withArgs(0, 0);

    [ehash, blockId, status] = await priorityOperations.pendingDeposits(2);
    expect(ehash).to.equal('0x0000000000000000000000000000000000000000000000000000000000000000');
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    [ehash, blockId, status] = await priorityOperations.pendingDeposits(3);
    h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[0].address, 3, 400]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(1);
    expect(status).to.equal(1);

    await expect(rollupChain.executeBlock(1, [], 0)).to.emit(rollupChain, 'RollupBlockExecuted').withArgs(1, 0);

    [ehash, blockId, status] = await priorityOperations.pendingDeposits(3);
    expect(ehash).to.equal('0x0000000000000000000000000000000000000000000000000000000000000000');
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);
  });
});
