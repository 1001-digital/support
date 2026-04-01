import { buildModule } from '@nomicfoundation/hardhat-ignition/modules'

export default buildModule('DiscountHookModule', (m) => {
  const minMonths = m.getParameter('minMonths')
  const percentOff = m.getParameter('percentOff')

  const discountHook = m.contract('DiscountHook', [minMonths, percentOff])

  return { discountHook }
})
