import { network } from 'hardhat'
import { writeFileSync, mkdirSync } from 'node:fs'
import { logo, tierPrices, tierNames, tierBadges } from '../lib/evmnow'

async function main() {
  const { viem } = await network.connect()

  const ETH_USD = 200000000000n // $2,000

  const priceFeed = await viem.deployContract('MockPriceFeed', [ETH_USD])
  const renderer = await viem.deployContract('SupportRenderer', [])
  for (let i = 0; i < tierBadges.length; i++) {
    const b = tierBadges[i]
    await renderer.write.setTierBadge([i, b.name, b.bg, b.tc, b.width])
  }
  const [deployer] = await viem.getWalletClients()
  const support = await viem.deployContract('SupportToken', [
    deployer.account.address,
    'EVM.NOW',
    'EVMNOW',
    priceFeed.address,
    tierPrices,
    0n,
    logo,
    renderer.address,
  ])

  const discountHook = await viem.deployContract('DiscountHook', [12, 20])
  await support.write.setHook([discountHook.address])

  const wallets = await viem.getWalletClients()

  mkdirSync('scripts/output', { recursive: true })

  for (let tier = 0; tier < tierPrices.length; tier++) {
    const wallet = wallets[tier]
    const cost = await support.read.cost([tier, 1])

    await support.write.support([wallet.account.address, tier, 1], {
      value: cost,
      account: wallet.account,
    })

    const tokenId = BigInt(tier + 1)
    const uri = await support.read.tokenURI([tokenId])
    const json = JSON.parse(Buffer.from(uri.split(',')[1], 'base64').toString())
    const svg = Buffer.from(json.image.split(',')[1], 'base64').toString()

    const file = `scripts/output/${tierNames[tier]}.svg`
    writeFileSync(file, svg)
    console.log(`Tier ${tier} (${tierNames[tier]}): ${file}`)
  }

  console.log('\nDone. Open scripts/output/*.svg to preview.')
}

main().catch(console.error)
