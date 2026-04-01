import { buildModule } from '@nomicfoundation/hardhat-ignition/modules'

export default buildModule('MaxSlotsHookModule', (m) => {
  const support = m.getParameter('support')

  const maxSlotsHook = m.contract('MaxSlotsHook', [support])

  return { maxSlotsHook }
})
