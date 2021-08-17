import * as dotenv from 'dotenv';
import { testStrategyCurve3Pool } from './StrategyCurve3Pool.spec';

dotenv.config();

describe('StrategyCurve3PoolDAI', async function () {
  it('should work', async function () {
    await testStrategyCurve3Pool(
      this,
      process.env.STRATEGY_CURVE_3POOL_DAI,
      process.env.DAI as string,
      18,
      0,
      process.env.DAI_FUNDER as string
    );
  });
});
