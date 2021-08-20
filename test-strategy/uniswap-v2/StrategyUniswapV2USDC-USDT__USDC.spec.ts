import * as dotenv from 'dotenv';
import { parseUnits } from 'ethers/lib/utils';

import { DESCRIPTION } from '../common';
import { testStrategyUniswapV2 } from './StrategyUniswapV2.spec';

dotenv.config();

describe('StrategyUniswapV2_USDC-USDT__USDC', function () {
  it(DESCRIPTION, async function () {
    await testStrategyUniswapV2(
      this,
      process.env.STRATEGY_UNISWAP_V2_USDC_USDT__USDC,
      'USDC',
      6,
      process.env.USDC as string,
      process.env.USDT as string,
      parseUnits('0.05', 18),
      parseUnits('500000', 6),
      process.env.USDC_FUNDER as string
    );
  });
});
