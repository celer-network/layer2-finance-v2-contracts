import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyBarnBridgePool } from './StrategyBarnBrigePool.spec';

dotenv.config();

describe('StrategyBarnBridgeCreamDAI', function () {
  it(DESCRIPTION, async function() {
    await testStrategyBarnBridgePool(
      this,
      'cream',
      process.env.STRATEGY_BARNBRIDGE_CREAM_DAI,
      process.env.DAI as string,
      'DAI',
      18,
      process.env.BARNBRIDGE_CRDAI as string,
      process.env.BARNBRIDGE_CRDAI_PROVIDER as string,
      process.env.BARNBRIDGE_CRDAI_YIELD as string,
      process.env.DAI_FUNDER as string
    )
  })
})
