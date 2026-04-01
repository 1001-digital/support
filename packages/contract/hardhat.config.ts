import hardhatToolboxViemPlugin from '@nomicfoundation/hardhat-toolbox-viem'
import { configVariable, defineConfig, task } from 'hardhat/config'
import { ArgumentType } from 'hardhat/types/arguments'
import type { HardhatPlugin } from 'hardhat/types/plugins'

const localTasks: HardhatPlugin = {
  id: 'local-tasks',
  tasks: [
    task('set-hook', 'Set a subscription hook on a deployed SupportToken')
      .addPositionalArgument({
        name: 'support',
        description: 'Address of the deployed SupportToken',
        type: ArgumentType.STRING,
      })
      .addPositionalArgument({
        name: 'hook',
        description:
          'Address of the deployed hook contract (use 0x0 to remove)',
        type: ArgumentType.STRING,
      })
      .setAction(() => import('./tasks/set-hook.js'))
      .build(),
  ],
}

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin, localTasks],
  solidity: {
    profiles: {
      default: {
        version: '0.8.28',
        settings: {
          viaIR: true,
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      production: {
        version: '0.8.28',
        settings: {
          viaIR: true,
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
  },
  networks: {
    hardhatMainnet: {
      type: 'edr-simulated',
      chainType: 'l1',
    },
    sepolia: {
      type: 'http',
      chainType: 'l1',
      url: configVariable('SEPOLIA_RPC_URL'),
      accounts: [configVariable('DEPLOYER_PRIVATE_KEY')],
    },
    mainnet: {
      type: 'http',
      chainType: 'l1',
      url: configVariable('MAINNET_RPC_URL'),
      accounts: [configVariable('DEPLOYER_PRIVATE_KEY')],
    },
  },
  verify: {
    etherscan: {
      apiKey: configVariable('ETHERSCAN_API_KEY'),
    },
  },
})
