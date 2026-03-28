import { network } from 'hardhat'
import { writeFileSync, mkdirSync } from 'node:fs'

// Logo SVG
const logo = [
  '<defs><linearGradient id="lg" x1="27.5" y1="13" x2="-3" y2="13" gradientUnits="userSpaceOnUse">',
  '<stop stop-color="#2B2B2B"/><stop offset="1" stop-color="#646464"/>',
  '</linearGradient></defs>',
  '<path d="M23 26H3V23H0V0H23V26Z" fill="url(#lg)"/>',
  '<path d="M6 8H9V11H6V8Z" fill="#F8F8F8"/>',
  '<path d="M6 11H9V14H6V11Z" fill="#F8F8F8"/>',
  '<path d="M9 11H12V14H9V11Z" fill="#F8F8F8"/>',
  '<path d="M12 11H15V14H12V11Z" fill="#F8F8F8"/>',
  '<path d="M6 14H9V17H6V14Z" fill="#F8F8F8"/>',
  '<path d="M9 17H12V20H9V17Z" fill="#F8F8F8"/>',
  '<path d="M12 17H15V20H12V17Z" fill="#F8F8F8"/>',
  '<path d="M15 17H18V20H15V17Z" fill="#F8F8F8"/>',
  '<path d="M9 5H12V8L9 8V5Z" fill="#F8F8F8"/>',
  '<path d="M12 5H15V8H12V5Z" fill="#F8F8F8"/>',
  '<path d="M6 5H9V8H6V5Z" fill="#F8F8F8"/>',
].join('')

const tierNames = ['supporter', 'gold', 'platinum', 'partner']

// $10, $69, $250, $1000 (8 decimals)
const tierPrices = [
  1000000000n,
  6900000000n,
  25000000000n,
  100000000000n,
] as const

async function main() {
  const { viem } = await network.connect()

  const ETH_USD = 200000000000n // $2,000

  const priceFeed = await viem.deployContract('MockPriceFeed', [ETH_USD])
  const support = await viem.deployContract('Support', [
    'EVM.NOW',
    'EVMNOW',
    logo,
    priceFeed.address,
    tierPrices,
    12,
    20,
  ])

  await support.write.setMaxSlots([3, 3])

  const wallets = await viem.getWalletClients()

  mkdirSync('scripts/output', { recursive: true })

  for (let tier = 0; tier < 4; tier++) {
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
