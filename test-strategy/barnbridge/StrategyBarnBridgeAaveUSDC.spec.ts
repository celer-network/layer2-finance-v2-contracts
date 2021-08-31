import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyBarnBridgePool } from './StrategyBarnBrigePool.spec';

dotenv.config();

describe('StrategyBarnBridgeAaveUSDC', function () {
  it(DESCRIPTION, async function() {
    await testStrategyBarnBridgePool(
      this,
      'aave',
      process.env.STRATEGY_BARNBRIDGE_AAVE_USDC,
      process.env.USDC as string,
      'USDC',
      6,
      process.env.BARNBRIDGE_AUSDC as string,
      process.env.BARNBRIDGE_AUSDC_PROVIDER as string,
      process.env.BARNBRIDGE_AUSDC_YIELD as string,
      process.env.USDC_FUNDER as string
    )
  })
})
