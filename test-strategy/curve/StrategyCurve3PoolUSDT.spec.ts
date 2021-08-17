import * as dotenv from 'dotenv';
import { testStrategyCurve3Pool } from './StrategyCurve3Pool.spec';

dotenv.config();

describe('StrategyCurve3PoolUSDT', async function () {
  it('should work', async function () {
    await testStrategyCurve3Pool(
      this,
      process.env.STRATEGY_CURVE_3POOL_USDT,
      process.env.USDT as string,
      6,
      2,
      process.env.CURVE_3POOL as string
    );
  });
});
