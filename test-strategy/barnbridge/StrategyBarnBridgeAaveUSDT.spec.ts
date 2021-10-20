import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyBarnBridgePool } from './StrategyBarnBrigePool.spec';

dotenv.config();

describe('StrategyBarnBridgeAaveUSDT', function () {
  it(DESCRIPTION, async function() {
    await testStrategyBarnBridgePool(
      this,
      'aave',
      process.env.STRATEGY_BARNBRIDGE_AAVE_USDT,
      process.env.USDT as string,
      'USDT',
      6,
      process.env.BARNBRIDGE_AUSDT as string,
      process.env.BARNBRIDGE_AUSDT_PROVIDER as string,
      process.env.BARNBRIDGE_AUSDT_YIELD as string,
      process.env.USDT_FUNDER as string
    )
  })
})
