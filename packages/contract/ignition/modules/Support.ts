import { buildModule } from '@nomicfoundation/hardhat-ignition/modules'

export default buildModule('SupportModule', (m) => {
  const initialOwner = m.getParameter('initialOwner')
  const projectName = m.getParameter('projectName')
  const projectSymbol = m.getParameter('projectSymbol')
  const logo = m.getParameter('logo')
  const priceFeed = m.getParameter('priceFeed')
  const tierPrices = m.getParameter('tierPrices')
  const saleStart = m.getParameter('saleStart')

  const renderer = m.contract('SupportRenderer', [])

  const support = m.contract('SupportToken', [
    initialOwner,
    projectName,
    projectSymbol,
    priceFeed,
    tierPrices,
    saleStart,
    logo,
    renderer,
    '0x0000000000000000000000000000000000000000',
  ])

  return { support, renderer }
})
