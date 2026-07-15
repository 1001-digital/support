import { createConfig } from 'ponder'

import { SupportAbi } from './abis/SupportAbi'

export default createConfig({
  chains: {
    ethereum: {
      id: 1,
      rpc: process.env.PONDER_RPC_URL_1!,
    },
  },
  contracts: {
    Support: {
      chain: 'ethereum',
      abi: SupportAbi,
      address: process.env.SUPPORT_ADDRESS! as `0x${string}`,
      startBlock: Number(process.env.SUPPORT_START_BLOCK ?? 0),
    },
  },
})
