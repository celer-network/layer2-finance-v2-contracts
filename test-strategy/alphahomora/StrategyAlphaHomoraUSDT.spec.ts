import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyAlphaHomoraErc20 } from './StrategyAlphaHomoraErc20.spec';

dotenv.config();

describe('StrategyAlphaHomoraUSDT', function () {
  it(DESCRIPTION, async function () {
    await testStrategyAlphaHomoraErc20(
      this,
      process.env.STRATEGY_ALPHAHOMORA_USDT,
      process.env.USDT as string,
      process.env.ALPHAHOMORA_IBUSDT as string,
      process.env.USDT_FUNDER as string,
      6, "USDT"
    );
  });
});
