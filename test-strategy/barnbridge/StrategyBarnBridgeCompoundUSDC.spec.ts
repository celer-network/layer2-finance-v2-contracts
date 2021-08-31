import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyBarnBridgePool } from './StrategyBarnBrigePool.spec';

dotenv.config();

describe('StrategyBarnBridgeCompoundUSDC', function () {
  it(DESCRIPTION, async function() {
    await testStrategyBarnBridgePool(
      this,
      'compound',
      process.env.STRATEGY_BARNBRIDGE_COMPUND_USDC,
      process.env.USDC as string,
      'USDC',
      6,
      process.env.BARNBRIDGE_CUSDC as string,
      process.env.BARNBRIDGE_CUSDC_PROVIDER as string,
      process.env.BARNBRIDGE_CUSDC_YIELD as string,
      process.env.USDC_FUNDER as string
    )
  })
})
