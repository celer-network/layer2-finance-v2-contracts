import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyBarnBridgePool } from './StrategyBarnBrigePool.spec';

dotenv.config();

describe('StrategyBarnBridgeCreamUSDC', function () {
  it(DESCRIPTION, async function() {
    await testStrategyBarnBridgePool(
      this,
      'cream',
      process.env.STRATEGY_BARNBRIDGE_CREAM_USDC,
      process.env.USDC as string,
      'USDC',
      6,
      process.env.BARNBRIDGE_CRUSDC as string,
      process.env.BARNBRIDGE_CRUSDC_PROVIDER as string,
      process.env.BARNBRIDGE_CRUSDC_YIELD as string,
      process.env.USDC_FUNDER as string
    )
  })
})
