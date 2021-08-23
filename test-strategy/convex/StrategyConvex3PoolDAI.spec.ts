import * as dotenv from 'dotenv';
import { testStrategyConvex3Pool } from './StrategyConvex3Pool.spec';

dotenv.config();

describe('StrategyCurve3PoolDAI', async function () {
  it('should work', async function () {
    await testStrategyConvex3Pool(
      this,
      process.env.STRATEGY_CONVEX_3POOL_DAI,
      process.env.DAI as string,
      18,
      0,
      process.env.DAI_FUNDER as string
    );
  });
});
