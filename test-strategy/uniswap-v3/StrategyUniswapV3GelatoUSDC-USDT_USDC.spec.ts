import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyUniswapV3Gelato } from './StrategyUniswapV3Gelato.spec';

dotenv.config();

describe('StrategyUniswapV3GelatoUSDC-USDT_USDC', function () {
  it(DESCRIPTION, async function () {
    await testStrategyUniswapV3Gelato(
      this,
      process.env.STRATEGY_UNISWAP_V3_GELATO_USDC_USDT__USDC,
      'USDC',
      6,
      process.env.USDC as string,
      process.env.GUNI_POOL_USDC_USDT as string,
      process.env.USDC_FUNDER as string
    );
  });
});
