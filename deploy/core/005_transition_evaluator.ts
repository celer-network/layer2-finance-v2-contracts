import * as dotenv from 'dotenv';
import { DeployFunction } from 'hardhat-deploy/types';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

dotenv.config();

const deployFunc: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  const transitionApplier1 = await deployments.get('TransitionApplier1');
  const transitionApplier2 = await deployments.get('TransitionApplier2');

  await deploy('TransitionEvaluator', {
    from: deployer,
    log: true,
    args: [transitionApplier1.address, transitionApplier2.address]
  });
};

deployFunc.tags = ['TransitionEvaluator'];
deployFunc.dependencies = ['TransitionApplier1', 'TransitionApplier2'];
export default deployFunc;
