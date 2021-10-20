import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyBarnBridgePool } from './StrategyBarnBrigePool.spec';

dotenv.config();

describe('StrategyBarnBridgeAaveDAI', function () {
  it(DESCRIPTION, async function() {
    await testStrategyBarnBridgePool(
      this,
      'aave',
      process.env.STRATEGY_BARNBRIDGE_AAVE_DAI,
      process.env.DAI as string,
      'DAI',
      18,
      process.env.BARNBRIDGE_ADAI as string,
      process.env.BARNBRIDGE_ADAI_PROVIDER as string,
      process.env.BARNBRIDGE_ADAI_YIELD as string,
      process.env.DAI_FUNDER as string
    )
  })
})
