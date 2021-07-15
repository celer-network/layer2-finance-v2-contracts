import * as dotenv from 'dotenv';
import { testStrategyCurve3Pool } from './StrategyCurve3Pool.spec';

dotenv.config();

describe('StrategyCurve3PoolDAI', async function () {
  it('should work', async function () {
    await testStrategyCurve3Pool(
      this,
      process.env.STRATEGY_CURVE_3POOL_DAI,
      0,
      process.env.CURVE_3POOL as string,
      process.env.CURVE_3POOL_3CRV as string,
      process.env.CURVE_3POOL_GAUGE as string,
      process.env.WETH_FUNDER as string
    );
  });
});
