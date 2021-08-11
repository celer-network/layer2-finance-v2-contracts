import * as dotenv from 'dotenv';

import { DESCRIPTION } from '../common';
import { testStrategyCompoundCreamLendingPool } from './StrategyCompoundCreamLendingPool.spec';

dotenv.config();

describe('StrategyCompoundCreamDAI', function () {
  it(DESCRIPTION, async function () {
    await testStrategyCompoundCreamLendingPool(
      this,
      process.env.STRATEGY_COMPOUND_CREAM_DAI,
      'DAI',
      18,
      process.env.DAI as string,
      process.env.COMPOUND_CDAI as string,
      process.env.CREAM_CRDAI as string,
      process.env.DAI_FUNDER as string
    );
  });
});
