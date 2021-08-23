import * as dotenv from 'dotenv';
import { testStrategyConvex3Pool } from './StrategyConvex3Pool.spec';

dotenv.config();

describe('StrategyCurve3PoolUSDC', async function () {
  it('should work', async function () {
    await testStrategyConvex3Pool(
      this,
      process.env.STRATEGY_CONVEX_3POOL_USDC,
      process.env.USDC as string,
      6,
      1,
      process.env.USDC_FUNDER as string
    );
  });
});
