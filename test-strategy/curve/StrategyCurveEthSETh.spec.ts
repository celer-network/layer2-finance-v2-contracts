import * as dotenv from 'dotenv';
import { testStrategyCurveEth } from './StrategyCurveEth.spec';

dotenv.config();

describe('StrategyCurveEthStEthETH', async function () {
  it('should work', async function () {
    await testStrategyCurveEth(
      this,
      process.env.STRATEGY_CURVE_ETH_STETH_ETH,
      0,
      process.env.CURVE_STETH as string,
      process.env.CURVE_STETH_LPTOKEN as string,
      process.env.CURVE_STETH_GAUGE as string,
      process.env.WETH_FUNDER as string
    );
  });
});
