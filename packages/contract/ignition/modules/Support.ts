import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("SupportModule", (m) => {
  const projectName = m.getParameter("projectName");
  const projectSymbol = m.getParameter("projectSymbol");
  const logo = m.getParameter("logo");
  const priceFeed = m.getParameter("priceFeed");
  const tierPrices = m.getParameter("tierPrices");
  const discountMinMonths = m.getParameter("discountMinMonths");
  const discountPercentOff = m.getParameter("discountPercentOff");
  const saleStart = m.getParameter("saleStart");

  const renderer = m.contract("SupportRenderer", []);

  const support = m.contract("SupportToken", [
    projectName,
    projectSymbol,
    logo,
    priceFeed,
    tierPrices,
    discountMinMonths,
    discountPercentOff,
    renderer,
    saleStart,
  ]);

  return { support, renderer };
});
