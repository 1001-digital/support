import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("SupportModule", (m) => {
  const projectName = m.getParameter("projectName");
  const projectSymbol = m.getParameter("projectSymbol");
  const logo = m.getParameter("logo");
  const priceFeed = m.getParameter("priceFeed");
  const tierPrices = m.getParameter("tierPrices");
  const discountMinMonths = m.getParameter("discountMinMonths");
  const discountPercentOff = m.getParameter("discountPercentOff");
  const renderer = m.contract("SupportRenderer", []);

  const support = m.contract("Support", [
    projectName,
    projectSymbol,
    logo,
    priceFeed,
    tierPrices,
    discountMinMonths,
    discountPercentOff,
    renderer,
  ]);

  return { support, renderer };
});
