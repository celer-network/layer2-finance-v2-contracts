import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyAlphaHomoraErc20 } from './StrategyAlphaHomoraErc20.spec';

dotenv.config();

describe('StrategyAlphaHomoraUSDC', function () {
  it(DESCRIPTION, async function () {
    await testStrategyAlphaHomoraErc20(
      this,
      process.env.STRATEGY_ALPHAHOMORA_USDC,
      process.env.USDC as string,
      process.env.ALPHAHOMORA_IBUSDC as string,
      process.env.USDC_FUNDER as string,
      6, "USDC"
    );
  });
});
