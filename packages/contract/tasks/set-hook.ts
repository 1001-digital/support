import type { HardhatRuntimeEnvironment } from "hardhat/types/hre";

const setHook = async (
  { support, hook }: { support: string; hook: string },
  hre: HardhatRuntimeEnvironment,
) => {
  const { viem } = await hre.network.connect();
  const [walletClient] = await viem.getWalletClients();

  const supportToken = await viem.getContractAt("SupportToken", support as `0x${string}`);

  const currentHook = await supportToken.read.hook();
  console.log(`Current hook: ${currentHook}`);

  const tx = await supportToken.write.setHook([hook as `0x${string}`]);
  console.log(`setHook tx: ${tx}`);

  const publicClient = await viem.getPublicClient();
  await publicClient.waitForTransactionReceipt({ hash: tx });

  const newHook = await supportToken.read.hook();
  console.log(`Hook set to: ${newHook}`);
};

export default setHook;
