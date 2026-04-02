import { buildModule } from '@nomicfoundation/hardhat-ignition/modules'
import { logo, tierPrices } from '../../lib/evmnow'

export default buildModule('EvmNowSupportersModule', (m) => {
  const initialOwner = m.getParameter('initialOwner')
  const priceFeed = m.getParameter('priceFeed')
  const saleStart = m.getParameter('saleStart')

  const renderer = m.contract('SupportRenderer', [])
  const hook = m.contract('EvmNowSupporterHook', [])

  const support = m.contract('SupportToken', [
    initialOwner,
    'EVM.NOW',
    'EVMNOW',
    priceFeed,
    tierPrices,
    saleStart,
    logo,
    renderer,
  ])

  m.call(support, 'setHook', [hook])

  return { support, renderer, hook }
})
