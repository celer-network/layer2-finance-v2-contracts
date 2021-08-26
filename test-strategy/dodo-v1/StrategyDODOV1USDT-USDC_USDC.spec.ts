import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyDODOV1 } from './StrategyDODOV1.spec';

dotenv.config();

describe('StrategyDODOV1USDC-USDT_USDC', function () {
  it(DESCRIPTION, async function () {
    await testStrategyDODOV1(
      this,
      process.env.STRATEGY_DODO_V1_USDT_USDC__USDC,
      'USDC',
      6,
      process.env.USDC as string,
      process.env.DODO_V1_USDT_USDC as string,
      process.env.USDC_FUNDER as string
    );
  });
});
