import * as dotenv from 'dotenv';
import { testStrategyConvex3Pool } from './StrategyConvex3Pool.spec';

dotenv.config();

describe('StrategyCurve3PoolUSDT', async function () {
  it('should work', async function () {
    await testStrategyConvex3Pool(
      this,
      process.env.STRATEGY_CONVEX_3POOL_USDT,
      process.env.USDT as string,
      6,
      2,
      process.env.USDT_FUNDER as string
    );
  });
});
