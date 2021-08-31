import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyBarnBridgePool } from './StrategyBarnBrigePool.spec';

dotenv.config();

describe('StrategyBarnBridgeCreamUSDT', function () {
  it(DESCRIPTION, async function() {
    await testStrategyBarnBridgePool(
      this,
      'cream',
      process.env.STRATEGY_BARNBRIDGE_CREAM_USDT,
      process.env.USDT as string,
      'USDT',
      6,
      process.env.BARNBRIDGE_CRUSDT as string,
      process.env.BARNBRIDGE_CRUSDT_PROVIDER as string,
      process.env.BARNBRIDGE_CRUSDT_YIELD as string,
      process.env.USDT_FUNDER as string
    )
  })
})
