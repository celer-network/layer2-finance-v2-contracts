import '@nomiclabs/hardhat-ethers';

import fs from 'fs';
import { ethers } from 'hardhat';
import path from 'path';

import { parseEther } from '@ethersproject/units';
import { Wallet } from '@ethersproject/wallet';

import { deployContracts, loadFixture } from '../test/common';

const GAS_USAGE_DIR = 'reports/gas_usage/';
const GAS_USAGE_LOG = path.join(GAS_USAGE_DIR, 'commit_block.txt');

const USER_KEY = '0x36f2243a51a0f879b1859fff1a663ac04aeebca1bcff4d7dc5a8b38e53211199';

describe('Benchmark commitBlock', async function () {
  if (!fs.existsSync(GAS_USAGE_DIR)) {
    fs.mkdirSync(GAS_USAGE_DIR, { recursive: true });
  }
  fs.rmSync(GAS_USAGE_LOG, { force: true });
  fs.appendFileSync(GAS_USAGE_LOG, '<tn num, gas cost> per block\n\n');

  async function fixture([admin]: Wallet[]) {
    const { rollupChain, dai } = await deployContracts(admin);

    const user = new Wallet(USER_KEY).connect(ethers.provider);
    await admin.sendTransaction({
      to: user.address,
      value: parseEther('10')
    });
    await dai.transfer(user.address, parseEther('10000'));

    return {
      rollupChain,
      dai,
      user
    };
  }

  async function doBenchmark(txType: string, data: string, maxNum: number) {
    it('one rollup block with up to ' + maxNum + ' ' + txType + ' transitions', async function () {
      this.timeout(20000 + 100 * maxNum);

      const { rollupChain, dai, user } = await loadFixture(fixture);
      if (txType == 'deposit') {
        const depNum = (maxNum * (maxNum + 1)) / 2 + 1;
        await dai.connect(user).approve(rollupChain.address, parseEther('1').mul(depNum));
      }
      fs.appendFileSync(GAS_USAGE_LOG, '-- ' + txType + ' --\n');
      let blockId = 0;
      let firstCost = 0;
      let lastCost = 0;
      for (let numTxs = 1; numTxs <= maxNum; numTxs++) {
        if (numTxs > 100 && numTxs % 100 != 0) {
          continue;
        }
        if (numTxs > 10 && numTxs % 10 != 0) {
          continue;
        }
        if (txType == 'deposit') {
          for (let i = 0; i < numTxs; i++) {
            await rollupChain.connect(user).deposit(dai.address, parseEther('1'));
          }
        }

        const txs = [];
        for (let i = 0; i < numTxs; i++) {
          txs.push(data);
        }
        const gasUsed = (
          await (
            await rollupChain.commitBlock(blockId, txs, {
              gasLimit: 9500000 // TODO: Remove once estimateGas() works correctly
            })
          ).wait()
        ).gasUsed;
        if (numTxs == 1) {
          firstCost = gasUsed.toNumber();
        }
        if (numTxs == maxNum) {
          lastCost = gasUsed.toNumber();
        }
        blockId++;
        fs.appendFileSync(GAS_USAGE_LOG, numTxs.toString() + '\t' + gasUsed + '\n');
      }
      const txCost = Math.ceil((lastCost - firstCost) / (maxNum - 1));
      fs.appendFileSync(GAS_USAGE_LOG, 'per tn cost after 1st tn: ' + txCost + '\n');
      fs.appendFileSync(GAS_USAGE_LOG, '\n');
    });
  }

  await doBenchmark(
    'transfer',
    '0x0000000000000002000000010000000200000000000000020000000000001c0646b669928f41596babb68108bad336f1363e6b56aa80fdb86b2ce86707ed980f000000000000000000000000c22c304660d5f1d2a7a459ceefc0c2cb30f5cfe40000000000000000000000000007a1200000000000000000000000000000000543d822aeca6d7bf517051baeab6467150fb9e874e0d36e5ddd93d408a1de383a203104e7414e8f875fd396356ec9302c7fd8e3e85bb10d2566505c7e6edda278',
    900
  );

  await doBenchmark(
    'deposit',
    '0x0000000000000000000000000000000000000001000000020000000000000002f382951514e9b09caadb325507594d353ff7069d35b75bf2d29c1b37a1488ab1000000000000000000000000c1699e89639adda8f39faefc0fc294ee5c3b462d0000000000000000000000000000000000000000000000000de0b6b3a7640000',
    50
  );

  await doBenchmark(
    'withdraw',
    '0x0000000100000001000000000000000100000000000000000000000000001b038aa1f943414722a64841354ae2a730e783c23238b1f4a40b622d017fe6e0d66c000000000000000000000000c1699e89639adda8f39faefc0fc294ee5c3b462d0000000000000000000000000000003200000000000000000000000000000000f69347286ce1b371e2d6d65b20625177f8b78309c902bea0558bdb4e9a8688974ad96c172ce60d2c33f41fa31af922ec838f5fb9bdc420e8cb35ef8532a8f80f',
    50
  );

  await doBenchmark(
    'buy/sell',
    '0x000000010000000100000000000000010000000000000f43fc2c04ee00001b04991a9c58a18c7c0b15144bd2d125dc2f96295ea530f38f1e72b0217b242ea5b2000000000000000006f05b59d3b200000000000000000000016345785d8a000090f491c0f97af1b3e82511a83877dcad27fa20e423cc550c09078ee1e8fcae3e7755157dca5eb7ff219f3122cf3c8426bfa1ad9bc2d1ca564149cb1b0d03d2f7',
    900
  );

  await doBenchmark(
    'settle',
    '0x000000010000000100000000000000000000000000000000000000000000000ab309594dbebd82e7877cbf01b84a6d904aab8b779fa73426965880cea5b04c23',
    900
  );
});
