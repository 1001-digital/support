import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { logo, tierPrices } from "../../lib/evmnow";

export default buildModule("EvmNowSupportersModule", (m) => {
  const priceFeed = m.getParameter("priceFeed");
  const saleStart = m.getParameter("saleStart");

  const renderer = m.contract("SupportRenderer", []);
  const hook = m.contract("EvmNowSupporterHook", []);

  const support = m.contract("SupportToken", [
    "EVM.NOW",
    "EVMNOW",
    logo,
    priceFeed,
    tierPrices,
    renderer,
    saleStart,
  ]);

  m.call(support, "setHook", [hook]);

  return { support, renderer, hook };
});
