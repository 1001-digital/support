import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("SupportModule", (m) => {
  const priceFeed = m.getParameter("priceFeed");
  const tierPrices = m.getParameter("tierPrices");
  const discountMinMonths = m.getParameter("discountMinMonths");
  const discountPercentOff = m.getParameter("discountPercentOff");

  const support = m.contract("Support", [
    priceFeed,
    tierPrices,
    discountMinMonths,
    discountPercentOff,
  ]);

  return { support };
});
