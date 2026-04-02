import { buildModule } from '@nomicfoundation/hardhat-ignition/modules'
import { logo, tierPrices, tierBadges } from '../../lib/evmnow'

export default buildModule('EvmNowSupportersModule', (m) => {
  const initialOwner = m.getParameter('initialOwner')
  const priceFeed = m.getParameter('priceFeed')
  const saleStart = m.getParameter('saleStart')

  const renderer = m.contract('SupportRenderer', [])
  for (const [i, b] of tierBadges.entries()) {
    m.call(renderer, 'setTierBadge', [i, b.name, b.bg, b.tc, b.width], { id: `badge${i}` })
  }
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
    hook,
  ])

  return { support, renderer, hook }
})
