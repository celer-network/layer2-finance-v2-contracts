import { expect } from 'chai';
import fs from 'fs';
import { ethers } from 'hardhat';

import { keccak256 as solidityKeccak256 } from '@ethersproject/solidity';
import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { deployContracts, getUsers, loadFixture, parseInput } from './common';

describe('DepositWithdraw', function () {
  async function fixture([admin]: Wallet[]) {
    const { registry, rollupChain, strategyDummy, strategyWeth, testERC20, weth } = await deployContracts(admin);

    const tokenAddress = testERC20.address;
    const wethAddress = weth.address;
    await registry.registerAsset(tokenAddress);
    await registry.registerAsset(wethAddress);

    await rollupChain.setNetDepositLimit(tokenAddress, parseEther('10000'));
    await rollupChain.setNetDepositLimit(wethAddress, parseEther('10000'));

    return {
      admin,
      registry,
      rollupChain,
      strategyDummy,
      strategyWeth,
      testERC20,
      weth
    };
  }

  it('should deposit and withdraw ERC20', async function () {
    const { admin, rollupChain, testERC20 } = await loadFixture(fixture);
    const users = await getUsers(admin, [testERC20], 1);
    const tokenAddress = testERC20.address;
    const depositAmount = 100;
    await testERC20.connect(users[0]).approve(rollupChain.address, depositAmount);
    await expect(rollupChain.connect(users[0]).deposit(tokenAddress, depositAmount))
      .to.emit(rollupChain, 'AssetDeposited')
      .withArgs(users[0].address, 1, depositAmount, 0);

    const [ehash, blockId, status] = await rollupChain.pendingDeposits(0);
    const h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[0].address, 1, depositAmount]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    const withdrawAmount = 50;
    await expect(rollupChain.connect(users[0]).withdraw(users[0].address, tokenAddress)).to.be.revertedWith(
      'invalid amount'
    );

    const { tns } = await parseInput('test/input/data/deposit-withdraw.txt');

    await rollupChain.commitBlock(0, tns[0]);

    const [account, assetId, amount] = await rollupChain.pendingWithdrawCommits(0, 0);
    expect(account).to.equal(users[0].address);
    expect(assetId).to.equal(1);
    expect(amount).to.equal(withdrawAmount);

    await rollupChain.executeBlock(0, [], 0);

    const totalAmount = await rollupChain.pendingWithdraws(users[0].address, assetId);
    expect(assetId).to.equal(1);
    expect(totalAmount).to.equal(withdrawAmount);

    const balanceBefore = await testERC20.balanceOf(users[0].address);
    await rollupChain.withdraw(users[0].address, tokenAddress);
    const balanceAfter = await testERC20.balanceOf(users[0].address);
    expect(balanceAfter.sub(balanceBefore)).to.equal(withdrawAmount);
  });

  it('should deposit and withdraw ETH', async function () {
    const { admin, rollupChain, weth } = await loadFixture(fixture);
    const users = await getUsers(admin, [], 1);
    const wethAddress = weth.address;
    const depositAmount = 100;
    await expect(
      rollupChain.connect(users[0]).depositETH(wethAddress, depositAmount, {
        value: depositAmount
      })
    )
      .to.emit(rollupChain, 'AssetDeposited')
      .withArgs(users[0].address, 2, depositAmount, 0);

    const [ehash, blockId, status] = await rollupChain.pendingDeposits(0);
    const h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[0].address, 2, depositAmount]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    const { tns } = await parseInput('test/input/data/deposit-withdraw-eth.txt');

    await rollupChain.commitBlock(0, tns[0]);

    const withdrawAmount = 50;
    const [account, assetId, amount] = await rollupChain.pendingWithdrawCommits(0, 0);
    expect(account).to.equal(users[0].address);
    expect(assetId).to.equal(2);
    expect(amount).to.equal(withdrawAmount);

    await rollupChain.executeBlock(0, [], 0);

    const totalAmount = await rollupChain.pendingWithdraws(users[0].address, assetId);
    expect(assetId).to.equal(2);
    expect(totalAmount).to.equal(withdrawAmount);

    const balanceBefore = await ethers.provider.getBalance(users[0].address);
    const withdrawTx = await rollupChain.connect(users[0]).withdrawETH(users[0].address, weth.address);
    const gasSpent = (await withdrawTx.wait()).gasUsed.mul(withdrawTx.gasPrice);
    const balanceAfter = await ethers.provider.getBalance(users[0].address);
    expect(balanceAfter.sub(balanceBefore).add(gasSpent)).to.equal(withdrawAmount);
  });

  it('should commit and execute blocks with multiple deposit transitions', async function () {
    const { admin, registry, rollupChain, strategyDummy, strategyWeth, testERC20, weth } = await loadFixture(fixture);
    await registry.registerStrategy(strategyDummy.address);
    await registry.registerStrategy(strategyWeth.address);

    const users = await getUsers(admin, [testERC20], 2);
    await testERC20.connect(users[0]).approve(rollupChain.address, parseEther('1'));
    await testERC20.connect(users[1]).approve(rollupChain.address, parseEther('1'));
    await rollupChain.connect(users[0]).deposit(testERC20.address, 100);
    await rollupChain.connect(users[1]).depositETH(weth.address, 200, { value: 200 });
    await rollupChain.connect(users[1]).deposit(testERC20.address, 300);
    await rollupChain.connect(users[0]).depositETH(weth.address, 400, { value: 400 });

    let [ehash, blockId, status] = await rollupChain.pendingDeposits(0);
    let h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[0].address, 1, 100]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    [ehash, blockId, status] = await rollupChain.pendingDeposits(1);
    h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[1].address, 2, 200]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    [ehash, blockId, status] = await rollupChain.pendingDeposits(2);
    h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[1].address, 1, 300]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    [ehash, blockId, status] = await rollupChain.pendingDeposits(3);
    h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[0].address, 2, 400]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    const { tns } = await parseInput('test/input/data/deposit-queue.txt');

    await expect(rollupChain.commitBlock(0, tns[1])).to.be.revertedWith('invalid data hash');
    await rollupChain.commitBlock(0, tns[0]);

    [, , status] = await rollupChain.pendingDeposits(2);
    expect(status).to.equal(1);
    [, , status] = await rollupChain.pendingDeposits(3);
    expect(status).to.equal(0);

    await rollupChain.commitBlock(1, tns[1]);
    [, , status] = await rollupChain.pendingDeposits(3);
    expect(status).to.equal(1);

    await expect(rollupChain.executeBlock(0, [], 0)).to.emit(rollupChain, 'RollupBlockExecuted').withArgs(0, 0);

    [ehash, blockId, status] = await rollupChain.pendingDeposits(2);
    expect(ehash).to.equal('0x0000000000000000000000000000000000000000000000000000000000000000');
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);

    [ehash, blockId, status] = await rollupChain.pendingDeposits(3);
    h = solidityKeccak256(['address', 'uint32', 'uint256'], [users[0].address, 2, 400]);
    expect(ehash).to.equal(h);
    expect(blockId).to.equal(1);
    expect(status).to.equal(1);

    await expect(rollupChain.executeBlock(1, [], 0)).to.emit(rollupChain, 'RollupBlockExecuted').withArgs(1, 0);

    [ehash, blockId, status] = await rollupChain.pendingDeposits(3);
    expect(ehash).to.equal('0x0000000000000000000000000000000000000000000000000000000000000000');
    expect(blockId).to.equal(0);
    expect(status).to.equal(0);
  });
});
