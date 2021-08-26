import * as dotenv from 'dotenv';
import { parseUnits } from 'ethers/lib/utils';

import { DESCRIPTION } from '../common';
import { testStrategySushiswap } from './StrategySushiswap.spec';

dotenv.config();

describe('StrategySushiswapUSDC-WETH', function () {
  it(DESCRIPTION, async function () {
    await testStrategySushiswap(
      this,
      process.env.STRATEGY_SUSHISWAP_USDC_WETH,
      'USDC',
      6,
      process.env.USDC as string,
      process.env.WETH as string,
      parseUnits('0.05', 18),
      parseUnits('500000', 6),
      1,
      process.env.USDC_FUNDER as string
    );
  });
});
