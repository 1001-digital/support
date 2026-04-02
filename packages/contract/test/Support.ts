import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { network } from 'hardhat'
import { getAddress, parseEther, zeroAddress } from 'viem'

const { viem } = await network.connect()
const publicClient = await viem.getPublicClient()
const [walletClient, otherWallet] = await viem.getWalletClients()

const ETH_USD = 200000000000n // $2,000

const tierPrices = [
  500000000n, // $5/mo
  1000000000n, // $10/mo
  2500000000n, // $25/mo
  5000000000n, // $50/mo
]

const discountMinMonths = 12
const discountPercentOff = 20

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

const tierBadges = [
  { name: 'SUPPORTER', bg: '#DCDCDC', tc: '#484848', width: 120 },
  { name: 'GOLD',      bg: '#A29C7A', tc: '#fff',    width: 81  },
  { name: 'PLATINUM',  bg: '#8B8F9A', tc: '#fff',    width: 109 },
  { name: 'PARTNER',   bg: '#000',    tc: '#fff',    width: 102 },
]

async function configureBadges(renderer: any) {
  for (const [i, b] of tierBadges.entries()) {
    await renderer.write.setTierBadge([i, b.name, b.bg, b.tc, b.width])
  }
}

async function readCost(support: any, args: [number, number]): Promise<bigint> {
  return (await support.read.estimate([...args, ZERO_ADDRESS]))[0]
}

describe('Support', async function () {
  async function deploy() {
    const priceFeed = await viem.deployContract('MockPriceFeed', [ETH_USD])
    const renderer = await viem.deployContract('SupportRenderer', [])
    await configureBadges(renderer)
    const support = await viem.deployContract('SupportToken', [
      walletClient.account.address,
      'TestProject',
      'TEST',
      priceFeed.address,
      tierPrices,
      0n,
      '<path d="M0 0"/>',
      renderer.address,
    ])

    const discountHook = await viem.deployContract('DiscountHook', [
      discountMinMonths,
      discountPercentOff,
    ])

    const hook = await viem.deployContract('MaxSlotsHook', [support.address])
    await support.write.setHook([hook.address])

    return { support, priceFeed, renderer, discountHook, hook }
  }

  // --- Cost ---

  it('Should calculate base cost', async function () {
    const { support, hook } = await deploy()
    assert.equal(await readCost(support, [0, 1]), parseEther('0.0025'))
    assert.equal(await readCost(support, [3, 1]), parseEther('0.025'))
  })

  it('Should apply discount at 12+ months', async function () {
    const { support, discountHook } = await deploy()
    await support.write.setHook([discountHook.address])
    // $5 * 12 = $60, 20% off = $48 / $2000 = 0.024 ETH
    assert.equal(await readCost(support, [0, 12]), parseEther('0.024'))
  })

  it('Should revert cost for invalid inputs', async function () {
    const { support, hook } = await deploy()
    await assert.rejects(readCost(support, [4, 1]), /InvalidTier/)
    await assert.rejects(readCost(support, [0, 0]), /InvalidDuration/)
  })

  // --- New subscription ---

  it('Should mint NFT on first support', async function () {
    const { support, hook } = await deploy()
    const ethCost = await readCost(support, [0, 1])

    await support.write.support([walletClient.account.address, 0, 1], {
      value: ethCost,
    })

    assert.equal(await support.read.totalSupply(), 1n)
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      1n,
    )
    assert.equal(
      await support.read.balanceOf([walletClient.account.address]),
      1n,
    )

    const segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 1)
    assert.equal(segs[0].tier, 0)
  })

  // --- Same-tier extension ---

  it('Should extend same tier without new segment', async function () {
    const { support, hook } = await deploy()
    const ethCost = await readCost(support, [0, 1])

    await support.write.support([walletClient.account.address, 0, 1], {
      value: ethCost,
    })
    const firstExpiry = await support.read.expiresAt([1n])

    await support.write.support([walletClient.account.address, 0, 1], {
      value: ethCost,
    })
    const secondExpiry = await support.read.expiresAt([1n])

    assert.equal(secondExpiry, firstExpiry + 30n * 24n * 60n * 60n)

    const segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 1) // no new segment
  })

  // --- Upgrade ---

  it('Should upgrade immediately and convert remaining time', async function () {
    const { support, priceFeed, hook } = await deploy()

    // Subscribe tier 0 ($5/mo) for 2 months
    await support.write.support([walletClient.account.address, 0, 2], {
      value: await readCost(support, [0, 2]),
    })

    // Advance 1 month — ~1 month remaining at tier 0
    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [30 * 24 * 60 * 60],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    // Upgrade to tier 2 ($25/mo) for 1 new month
    // Remaining ~30 days at $5 converts to ~6 days at $25 (5/25 ratio)
    // Plus 1 new month at $25 = 30 days
    // Total ~36 days from now (> 30d minimum)
    // Cost: only 1 month at $25 = $25
    const block = await publicClient.getBlock()
    const expiryBefore = await support.read.expiresAt([1n])
    const remaining = expiryBefore - block.timestamp

    const hash = await support.write.support(
      [walletClient.account.address, 2, 1],
      { value: parseEther('1') },
    )
    const receipt = await publicClient.getTransactionReceipt({ hash })
    const events = await publicClient.getContractEvents({
      address: support.address,
      abi: support.abi,
      eventName: 'Supported',
      fromBlock: receipt.blockNumber,
      toBlock: receipt.blockNumber,
    })

    // Paid should be > 0 and < 1 ETH (the overpay)
    const paid = events[0].args.paid!
    assert.ok(paid > 0n)
    assert.ok(paid < parseEther('1'))

    // Expiry = now + converted remaining + 1 month
    const expiryAfter = await support.read.expiresAt([1n])
    const converted = remaining * 5n / 25n
    const expectedExpiry = block.timestamp + converted + 30n * 24n * 60n * 60n

    // Allow 5 second tolerance for block timestamp drift
    assert.ok(expiryAfter >= expectedExpiry - 5n)
    assert.ok(expiryAfter <= expectedExpiry + 5n)

    // Current tier is now 2
    const [tier, active] = await support.read.currentTier([1n])
    assert.equal(tier, 2)
    assert.equal(active, true)

    // Two segments: tier 0, then tier 2
    const segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 2)
    assert.equal(segs[0].tier, 0)
    assert.equal(segs[1].tier, 2)
  })

  it('Should upgrade with duration 0 (convert time, 30d minimum)', async function () {
    const { support, hook } = await deploy()

    await support.write.support([walletClient.account.address, 0, 2], {
      value: await readCost(support, [0, 2]),
    })

    // Upgrade to tier 2 with duration 0 — free, remaining time converts
    // ~60 days at $5 converts to ~12 days at $25 (5/25 ratio)
    // 12 days < 30d minimum, so expiry = now + 30 days
    await support.write.support([walletClient.account.address, 2, 0], {
      value: 0n,
    })

    const block = await publicClient.getBlock()
    const expiryAfter = await support.read.expiresAt([1n])
    const minExpiry = block.timestamp + 30n * 24n * 60n * 60n

    // Should be at least 30 days from now (the minimum)
    assert.ok(expiryAfter >= minExpiry - 5n)
    assert.ok(expiryAfter <= minExpiry + 5n)

    const [tier] = await support.read.currentTier([1n])
    assert.equal(tier, 2)
  })

  it('Should downgrade with duration 0 (just convert time)', async function () {
    const { support, hook } = await deploy()

    await support.write.support([walletClient.account.address, 2, 1], {
      value: await readCost(support, [2, 1]),
    })
    const expiryBefore = await support.read.expiresAt([1n])

    // Downgrade to tier 0 with duration 0 — free, remaining time converts
    await support.write.support([walletClient.account.address, 0, 0], {
      value: 0n,
    })

    const expiryAfter = await support.read.expiresAt([1n])
    assert.ok(expiryAfter > expiryBefore) // converted time is longer

    const [tier] = await support.read.currentTier([1n])
    assert.equal(tier, 0)
  })

  it('Should revert duration 0 for new subscription', async function () {
    const { support, hook } = await deploy()
    await assert.rejects(
      support.write.support([walletClient.account.address, 0, 0], {
        value: 0n,
      }),
      /InvalidDuration/,
    )
  })

  it('Should revert duration 0 for same-tier extension', async function () {
    const { support, hook } = await deploy()
    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })

    await assert.rejects(
      support.write.support([walletClient.account.address, 0, 0], {
        value: 0n,
      }),
      /InvalidDuration/,
    )
  })

  // --- Downgrade ---

  it('Should downgrade immediately and extend duration', async function () {
    const { support, priceFeed, hook } = await deploy()

    // Subscribe tier 2 ($25/mo) for 1 month
    await support.write.support([walletClient.account.address, 2, 1], {
      value: await readCost(support, [2, 1]),
    })

    // Advance 15 days — ~15 days remaining at tier 2
    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [15 * 24 * 60 * 60],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    const block = await publicClient.getBlock()
    const expiryBefore = await support.read.expiresAt([1n])
    const remaining = expiryBefore - block.timestamp

    // Downgrade to tier 0 ($5/mo) for 1 new month
    // Remaining ~15 days at $25 converts to ~75 days at $5 (5x)
    // Plus 30 days new = ~105 days total from now
    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })

    const expiryAfter = await support.read.expiresAt([1n])
    // Converted remaining = remaining * 25 / 5 = remaining * 5
    const expectedExpiry =
      block.timestamp + remaining * 5n + 30n * 24n * 60n * 60n

    // Allow 5 second tolerance for block timestamp drift
    assert.ok(expiryAfter >= expectedExpiry - 5n)
    assert.ok(expiryAfter <= expectedExpiry + 5n)

    const [tier] = await support.read.currentTier([1n])
    assert.equal(tier, 0)

    const segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 2)
  })

  it('Should reject setting tier price to zero', async function () {
    const { support } = await deploy()

    await assert.rejects(
      support.write.setTierPrice([0, 0n]),
      /InvalidPrice/,
    )
  })

  // --- Subscription expiry + token reuse ---

  it('Should reuse token on re-subscribe after expiry', async function () {
    const { support, priceFeed, hook } = await deploy()

    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })

    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [30 * 24 * 60 * 60 + 1],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    await support.write.support([walletClient.account.address, 2, 1], {
      value: await readCost(support, [2, 1]),
    })

    // Same token reused — no new mint
    assert.equal(await support.read.totalSupply(), 1n)
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      1n,
    )
    assert.equal(
      await support.read.balanceOf([walletClient.account.address]),
      1n,
    )

    // Token is reactivated with new tier
    const [tier, active] = await support.read.currentTier([1n])
    assert.equal(tier, 2)
    assert.equal(active, true)

    // tierPeriods reset to single entry
    const segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 1)
    assert.equal(segs[0].tier, 2)
  })

  it('Should return inactive for expired token', async function () {
    const { support, hook } = await deploy()

    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })

    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [30 * 24 * 60 * 60 + 1],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })

    const [, active] = await support.read.currentTier([1n])
    assert.equal(active, false)
  })

  // --- Refund ---

  it('Should refund excess and emit correct paid', async function () {
    const { support, hook } = await deploy()
    const ethCost = await readCost(support, [0, 1])
    const overpay = ethCost + parseEther('0.5')

    const balanceBefore = await publicClient.getBalance({
      address: walletClient.account.address,
    })
    const hash = await support.write.support(
      [walletClient.account.address, 0, 1],
      { value: overpay },
    )
    const receipt = await publicClient.getTransactionReceipt({ hash })
    const gasUsed = receipt.gasUsed * receipt.effectiveGasPrice
    const balanceAfter = await publicClient.getBalance({
      address: walletClient.account.address,
    })

    assert.equal(balanceAfter, balanceBefore - ethCost - gasUsed)
  })

  it('Should revert on insufficient payment', async function () {
    const { support, hook } = await deploy()
    await assert.rejects(
      support.write.support([walletClient.account.address, 0, 1], {
        value: 1n,
      }),
      /InsufficientPayment/,
    )
  })

  // --- Oracle ---

  it('Should revert on stale/zero/bad-round price', async function () {
    const { support, priceFeed, hook } = await deploy()

    await priceFeed.write.setPrice([0n])
    await assert.rejects(readCost(support, [0, 1]), /StalePrice/)

    await priceFeed.write.setPrice([ETH_USD])
    await priceFeed.write.setAnsweredInRound([0])
    await assert.rejects(readCost(support, [0, 1]), /StalePrice/)
  })

  // --- Owner ---

  it('Should allow owner functions', async function () {
    const { support, discountHook, hook } = await deploy()

    await support.write.setTierPrice([0, 750000000n])
    assert.equal(await support.read.tierPrices([0]), 750000000n)

    await discountHook.write.setDiscount([6, 10])
    assert.equal(await discountHook.read.minMonths(), 6)

    await support.write.setLogo(['<path d="M0 0"/>'])
    assert.equal(await support.read.logo(), '<path d="M0 0"/>')

    await hook.write.setMaxSlots([3, 5])
    assert.equal(await hook.read.maxSlots([3]), 5)
  })

  it('Should allow withdraw', async function () {
    const { support, hook } = await deploy()
    const ethCost = await readCost(support, [0, 1])
    await support.write.support([walletClient.account.address, 0, 1], {
      value: ethCost,
    })

    const balanceBefore = await publicClient.getBalance({
      address: walletClient.account.address,
    })
    const hash = await support.write.withdraw()
    const receipt = await publicClient.getTransactionReceipt({ hash })
    const gasUsed = receipt.gasUsed * receipt.effectiveGasPrice
    const balanceAfter = await publicClient.getBalance({
      address: walletClient.account.address,
    })

    assert.equal(balanceAfter, balanceBefore + ethCost - gasUsed)
  })

  it('Should reject non-owner calls', async function () {
    const { support, hook } = await deploy()
    await assert.rejects(
      support.write.setTierPrice([0, 1n], { account: otherWallet.account }),
      /OwnableUnauthorizedAccount/,
    )
    await assert.rejects(
      support.write.withdraw({ account: otherWallet.account }),
      /OwnableUnauthorizedAccount/,
    )
  })

  it('Should transfer ownership via two-step process', async function () {
    const { support, hook } = await deploy()

    // Step 1: propose new owner
    await support.write.transferOwnership([otherWallet.account.address])
    // Owner unchanged until accepted
    assert.equal(
      await support.read.owner(),
      getAddress(walletClient.account.address),
    )
    assert.equal(
      await support.read.pendingOwner(),
      getAddress(otherWallet.account.address),
    )

    // Step 2: new owner accepts
    await support.write.acceptOwnership({ account: otherWallet.account })
    assert.equal(
      await support.read.owner(),
      getAddress(otherWallet.account.address),
    )
  })

  it('Should reject acceptOwnership from non-pending address', async function () {
    const { support, hook } = await deploy()
    await support.write.transferOwnership([otherWallet.account.address])
    await assert.rejects(
      support.write.acceptOwnership({ account: walletClient.account }),
      /OwnableUnauthorizedAccount/,
    )
  })

  // --- NFT Transfer ---

  it('Should emit Transfer on mint, not on extension', async function () {
    const { support, hook } = await deploy()
    const ethCost = await readCost(support, [0, 1])

    const hash1 = await support.write.support(
      [walletClient.account.address, 0, 1],
      { value: ethCost },
    )
    const receipt1 = await publicClient.getTransactionReceipt({ hash: hash1 })
    const mints = await publicClient.getContractEvents({
      address: support.address,
      abi: support.abi,
      eventName: 'Transfer',
      fromBlock: receipt1.blockNumber,
      toBlock: receipt1.blockNumber,
    })
    assert.equal(mints.length, 1)

    const hash2 = await support.write.support(
      [walletClient.account.address, 0, 1],
      { value: ethCost },
    )
    const receipt2 = await publicClient.getTransactionReceipt({ hash: hash2 })
    const noMints = await publicClient.getContractEvents({
      address: support.address,
      abi: support.abi,
      eventName: 'Transfer',
      fromBlock: receipt2.blockNumber,
      toBlock: receipt2.blockNumber,
    })
    assert.equal(noMints.length, 0)
  })

  it('Should transfer NFT and subscription', async function () {
    const { support, hook } = await deploy()
    await support.write.support([walletClient.account.address, 2, 3], {
      value: await readCost(support, [2, 3]),
    })

    await support.write.transferFrom([
      walletClient.account.address,
      otherWallet.account.address,
      1n,
    ])

    assert.equal(
      await support.read.ownerOf([1n]),
      getAddress(otherWallet.account.address),
    )
    assert.equal(
      await support.read.balanceOf([walletClient.account.address]),
      0n,
    )
    assert.equal(
      await support.read.balanceOf([otherWallet.account.address]),
      1n,
    )

    // Active subscription moves with the NFT
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      0n,
    )
    assert.equal(
      await support.read.subscription([otherWallet.account.address]),
      1n,
    )

    const [tier, active] = await support.read.currentTier([1n])
    assert.equal(tier, 2)
    assert.equal(active, true)
  })

  it('Should allow approved transfer', async function () {
    const { support, hook } = await deploy()
    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })

    await support.write.approve([otherWallet.account.address, 1n])
    await support.write.transferFrom(
      [walletClient.account.address, otherWallet.account.address, 1n],
      { account: otherWallet.account },
    )

    assert.equal(
      await support.read.ownerOf([1n]),
      getAddress(otherWallet.account.address),
    )
  })

  it('Should revert transfer to address that already holds a token', async function () {
    const { support, hook } = await deploy()

    // Both wallets subscribe
    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })
    await support.write.support([otherWallet.account.address, 2, 3], {
      value: await readCost(support, [2, 3]),
      account: otherWallet.account,
    })

    // Transfer to otherWallet who already has a token — should revert
    await assert.rejects(
      support.write.transferFrom([
        walletClient.account.address,
        otherWallet.account.address,
        1n,
      ]),
      /OneTokenPerWallet/,
    )
  })

  it("Should set receiver's subscription if they have none", async function () {
    const { support, hook } = await deploy()

    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })

    // otherWallet has no subscription
    assert.equal(
      await support.read.subscription([otherWallet.account.address]),
      0n,
    )

    await support.write.transferFrom([
      walletClient.account.address,
      otherWallet.account.address,
      1n,
    ])

    // Now otherWallet inherits the active subscription
    assert.equal(
      await support.read.subscription([otherWallet.account.address]),
      1n,
    )
  })

  it('Should track expired token on transfer for future reuse', async function () {
    const { support, hook } = await deploy()

    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })

    // Fast-forward past expiry
    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [31 * 86400],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })

    // Transfer expired NFT
    await support.write.transferFrom([
      walletClient.account.address,
      otherWallet.account.address,
      1n,
    ])

    assert.equal(
      await support.read.ownerOf([1n]),
      getAddress(otherWallet.account.address),
    )

    // Raw mapping tracks token for reuse, but no active subscription
    assert.equal(
      await support.read.subscription([otherWallet.account.address]),
      1n,
    )
    assert.equal(
      await support.read.isActive([otherWallet.account.address]),
      false,
    )
  })

  it('Should mint new token when re-subscribing after transferring away', async function () {
    const { support, hook } = await deploy()

    await support.write.support([walletClient.account.address, 0, 3], {
      value: await readCost(support, [0, 3]),
    })

    // Transfer token to other wallet
    await support.write.transferFrom([
      walletClient.account.address,
      otherWallet.account.address,
      1n,
    ])
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      0n,
    )
    assert.equal(
      await support.read.balanceOf([walletClient.account.address]),
      0n,
    )

    // Re-subscribe — should mint a new token since wallet has none
    await support.write.support([walletClient.account.address, 1, 1], {
      value: await readCost(support, [1, 1]),
    })
    assert.equal(await support.read.totalSupply(), 2n)
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      2n,
    )
    assert.equal(
      await support.read.balanceOf([walletClient.account.address]),
      1n,
    )
  })

  it('Should reactivate transferred expired token when receiver subscribes', async function () {
    const { support, priceFeed, hook } = await deploy()

    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })

    // Expire
    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [31 * 86400],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    // Transfer expired token to other wallet
    await support.write.transferFrom([
      walletClient.account.address,
      otherWallet.account.address,
      1n,
    ])

    // Other wallet subscribes — should reactivate the transferred token
    await support.write.support([otherWallet.account.address, 2, 1], {
      value: await readCost(support, [2, 1]),
      account: otherWallet.account,
    })

    assert.equal(await support.read.totalSupply(), 1n) // no new mint
    assert.equal(
      await support.read.subscription([otherWallet.account.address]),
      1n,
    )
    const [tier, active] = await support.read.currentTier([1n])
    assert.equal(tier, 2)
    assert.equal(active, true)

    // tierPeriods reset
    const segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 1)
    assert.equal(segs[0].tier, 2)
  })

  it('Should revert unauthorized transfer', async function () {
    const { support, hook } = await deploy()
    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })

    await assert.rejects(
      support.write.transferFrom(
        [walletClient.account.address, otherWallet.account.address, 1n],
        { account: otherWallet.account },
      ),
      /ERC721InsufficientApproval/,
    )
  })

  it('Should support ERC-165/721/4906 interfaces', async function () {
    const { support, hook } = await deploy()
    assert.equal(await support.read.supportsInterface(['0x01ffc9a7']), true)
    assert.equal(await support.read.supportsInterface(['0x80ac58cd']), true)
    assert.equal(await support.read.supportsInterface(['0x5b5e139f']), true)
    assert.equal(await support.read.supportsInterface(['0x49064906']), true)
    assert.equal(await support.read.supportsInterface(['0xffffffff']), false)
  })

  // --- tokenURI ---

  it('Should build active tokenURI with project name and badge', async function () {
    const { support, hook } = await deploy()
    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })

    const uri = await support.read.tokenURI([1n])
    const json = JSON.parse(Buffer.from(uri.split(',')[1], 'base64').toString())

    assert.equal(json.name, 'TestProject #1')

    const svg = Buffer.from(json.image.split(',')[1], 'base64').toString()
    assert.ok(svg.includes('TestProject'))
    assert.ok(svg.includes('ACTIVE'))
    assert.ok(svg.includes('DAY 1'))
    assert.ok(svg.includes('0x'))
    assert.ok(svg.includes('...'))

    assert.equal(
      json.attributes.find((a: any) => a.trait_type === 'Status').value,
      'Active',
    )
    assert.equal(
      json.attributes.find((a: any) => a.trait_type === 'Tier').value,
      0,
    )
  })

  it('Should build expired tokenURI with last tier badge', async function () {
    const { support, hook } = await deploy()

    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })
    await support.write.support([walletClient.account.address, 2, 1], {
      value: parseEther('1'),
    })

    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [90 * 24 * 60 * 60],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })

    const uri = await support.read.tokenURI([1n])
    const json = JSON.parse(Buffer.from(uri.split(',')[1], 'base64').toString())

    const svg = Buffer.from(json.image.split(',')[1], 'base64').toString()
    assert.ok(svg.includes('EXPIRED'))

    assert.equal(
      json.attributes.find((a: any) => a.trait_type === 'Status').value,
      'Expired',
    )
    assert.equal(
      json.attributes.find((a: any) => a.trait_type === 'Tier').value,
      2,
    )
    assert.ok(json.attributes.find((a: any) => a.trait_type === 'Tier Period 1'))
    assert.ok(json.attributes.find((a: any) => a.trait_type === 'Tier Period 2'))
  })

  // --- Tier slot limits ---

  it('Should enforce and free tier slots', async function () {
    const wallets = await viem.getWalletClients()
    const { support, priceFeed, hook } = await deploy()

    await hook.write.setMaxSlots([3, 1])

    const cost3 = await readCost(support, [3, 1])
    await support.write.support([wallets[0].account.address, 3, 1], {
      value: cost3,
      account: wallets[0].account,
    })

    // Slot full
    await assert.rejects(
      support.write.support([wallets[1].account.address, 3, 1], {
        value: cost3,
        account: wallets[1].account,
      }),
      /SubscriptionBlocked/,
    )

    // Holder downgrades — frees slot
    await support.write.support([wallets[0].account.address, 0, 1], {
      value: parseEther('1'),
      account: wallets[0].account,
    })

    await support.write.support([wallets[1].account.address, 3, 1], {
      value: cost3,
      account: wallets[1].account,
    })
    const holders = await hook.read.tierHolders([3])
    assert.equal(holders[0], getAddress(wallets[1].account.address))
  })

  it('Should free slot on expiry', async function () {
    const wallets = await viem.getWalletClients()
    const { support, priceFeed, hook } = await deploy()

    await hook.write.setMaxSlots([3, 1])
    await support.write.support([wallets[0].account.address, 3, 1], {
      value: await readCost(support, [3, 1]),
      account: wallets[0].account,
    })

    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [30 * 24 * 60 * 60 + 1],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    await support.write.support([wallets[1].account.address, 3, 1], {
      value: await readCost(support, [3, 1]),
      account: wallets[1].account,
    })
    const holders = await hook.read.tierHolders([3])
    assert.equal(holders[0], getAddress(wallets[1].account.address))
  })

  // --- activeTierHolders ---

  it('Should filter expired holders from activeTierHolders', async function () {
    const wallets = await viem.getWalletClients()
    const { support, priceFeed, hook } = await deploy()

    await hook.write.setMaxSlots([3, 3])
    const cost3 = await readCost(support, [3, 1])

    // Three holders subscribe to tier 3
    await support.write.support([wallets[0].account.address, 3, 1], {
      value: cost3,
      account: wallets[0].account,
    })
    await support.write.support([wallets[1].account.address, 3, 1], {
      value: cost3,
      account: wallets[1].account,
    })
    await support.write.support([wallets[2].account.address, 3, 2], {
      value: await readCost(support, [3, 2]),
      account: wallets[2].account,
    })

    // All three appear in both views
    assert.equal((await hook.read.tierHolders([3])).length, 3)
    assert.equal((await hook.read.activeTierHolders([3])).length, 3)

    // Expire wallets[0] and wallets[1]
    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [30 * 24 * 60 * 60 + 1],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    // Raw array still has 3 entries, but only wallets[2] is active
    assert.equal((await hook.read.tierHolders([3])).length, 3)
    const active = await hook.read.activeTierHolders([3])
    assert.equal(active.length, 1)
    assert.equal(active[0], getAddress(wallets[2].account.address))
  })

  it('Should filter tier-changed holders from activeTierHolders', async function () {
    const wallets = await viem.getWalletClients()
    const { support, hook } = await deploy()

    await hook.write.setMaxSlots([2, 2])
    await hook.write.setMaxSlots([3, 2])

    // Two holders in tier 3
    const cost3 = await readCost(support, [3, 2])
    await support.write.support([wallets[0].account.address, 3, 2], {
      value: cost3,
      account: wallets[0].account,
    })
    await support.write.support([wallets[1].account.address, 3, 2], {
      value: cost3,
      account: wallets[1].account,
    })

    assert.equal((await hook.read.activeTierHolders([3])).length, 2)

    // wallets[0] downgrades to tier 2
    await support.write.support([wallets[0].account.address, 2, 1], {
      value: parseEther('1'),
      account: wallets[0].account,
    })

    // Tier 3 should only show wallets[1]
    const active3 = await hook.read.activeTierHolders([3])
    assert.equal(active3.length, 1)
    assert.equal(active3[0], getAddress(wallets[1].account.address))

    // Tier 2 should show wallets[0]
    const active2 = await hook.read.activeTierHolders([2])
    assert.equal(active2.length, 1)
    assert.equal(active2[0], getAddress(wallets[0].account.address))
  })

  it('Should return empty for activeTierHolders when maxSlots is 0', async function () {
    const { support, hook } = await deploy()

    // maxSlots defaults to 0 (unlimited / no tracking)
    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })

    const active = await hook.read.activeTierHolders([0])
    assert.equal(active.length, 0)
  })

  // --- Tier slot compaction ---

  it('Should compact tier array on downgrade via swap-and-pop', async function () {
    const wallets = await viem.getWalletClients()
    const { support, hook } = await deploy()

    await hook.write.setMaxSlots([3, 3])
    const cost3 = await readCost(support, [3, 2])

    // Fill 3 slots: [w0, w1, w2]
    await support.write.support([wallets[0].account.address, 3, 2], {
      value: cost3,
      account: wallets[0].account,
    })
    await support.write.support([wallets[1].account.address, 3, 2], {
      value: cost3,
      account: wallets[1].account,
    })
    await support.write.support([wallets[2].account.address, 3, 2], {
      value: cost3,
      account: wallets[2].account,
    })
    assert.equal((await hook.read.tierHolders([3])).length, 3)

    // w0 downgrades — array should shrink to 2 via swap-and-pop: [w2, w1]
    await support.write.support([wallets[0].account.address, 0, 1], {
      value: parseEther('1'),
      account: wallets[0].account,
    })
    const holders = await hook.read.tierHolders([3])
    assert.equal(holders.length, 2)

    // w1 downgrades — array should shrink to 1: [w2]
    await support.write.support([wallets[1].account.address, 0, 1], {
      value: parseEther('1'),
      account: wallets[1].account,
    })
    const holders2 = await hook.read.tierHolders([3])
    assert.equal(holders2.length, 1)
    assert.equal(holders2[0], getAddress(wallets[2].account.address))
  })

  it('Should allow new subscriber after compaction frees a slot', async function () {
    const wallets = await viem.getWalletClients()
    const { support, hook } = await deploy()

    await hook.write.setMaxSlots([3, 2])
    const cost3 = await readCost(support, [3, 2])
    const cost3Single = await readCost(support, [3, 1])

    // Fill both slots
    await support.write.support([wallets[0].account.address, 3, 2], {
      value: cost3,
      account: wallets[0].account,
    })
    await support.write.support([wallets[1].account.address, 3, 2], {
      value: cost3,
      account: wallets[1].account,
    })

    // Full — cost() also reverts when tier is blocked, so use pre-computed price
    await assert.rejects(
      support.write.support([wallets[2].account.address, 3, 1], {
        value: cost3Single,
        account: wallets[2].account,
      }),
      /SubscriptionBlocked/,
    )

    // w0 downgrades — compacts array, freeing a slot
    await support.write.support([wallets[0].account.address, 0, 1], {
      value: parseEther('1'),
      account: wallets[0].account,
    })
    assert.equal((await hook.read.tierHolders([3])).length, 1)

    // w2 can now join
    await support.write.support([wallets[2].account.address, 3, 1], {
      value: await readCost(support, [3, 1]),
      account: wallets[2].account,
    })
    const holders = await hook.read.tierHolders([3])
    assert.equal(holders.length, 2)
  })

  // --- O(1) duplicate check ---

  it('Should not duplicate holder on same-tier extension', async function () {
    const { support, hook } = await deploy()

    await hook.write.setMaxSlots([0, 2])
    const cost0 = await readCost(support, [0, 1])

    await support.write.support([walletClient.account.address, 0, 1], {
      value: cost0,
    })
    await support.write.support([walletClient.account.address, 0, 1], {
      value: cost0,
    })
    await support.write.support([walletClient.account.address, 0, 1], {
      value: cost0,
    })

    const holders = await hook.read.tierHolders([0])
    assert.equal(holders.length, 1)
    assert.equal(holders[0], getAddress(walletClient.account.address))
  })

  // --- Re-subscribe after expiry ---

  it('Should remove from old tier when re-subscribing to different tier after expiry', async function () {
    const wallets = await viem.getWalletClients()
    const { support, priceFeed, hook } = await deploy()

    await hook.write.setMaxSlots([0, 2])
    await hook.write.setMaxSlots([3, 2])

    // Subscribe to tier 3
    await support.write.support([wallets[0].account.address, 3, 1], {
      value: await readCost(support, [3, 1]),
      account: wallets[0].account,
    })
    assert.equal((await hook.read.tierHolders([3])).length, 1)

    // Expire
    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [30 * 24 * 60 * 60 + 1],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    // Re-subscribe to tier 0
    await support.write.support([wallets[0].account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
      account: wallets[0].account,
    })

    // Should be removed from tier 3, added to tier 0
    assert.equal((await hook.read.tierHolders([3])).length, 0)
    const holders0 = await hook.read.tierHolders([0])
    assert.equal(holders0.length, 1)
    assert.equal(holders0[0], getAddress(wallets[0].account.address))
  })

  it('Should keep holder in same tier when re-subscribing after expiry', async function () {
    const wallets = await viem.getWalletClients()
    const { support, priceFeed, hook } = await deploy()

    await hook.write.setMaxSlots([3, 2])

    await support.write.support([wallets[0].account.address, 3, 1], {
      value: await readCost(support, [3, 1]),
      account: wallets[0].account,
    })
    assert.equal((await hook.read.tierHolders([3])).length, 1)

    // Expire
    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [30 * 24 * 60 * 60 + 1],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    // Re-subscribe to same tier
    await support.write.support([wallets[0].account.address, 3, 1], {
      value: await readCost(support, [3, 1]),
      account: wallets[0].account,
    })

    // Still one entry, no duplicate
    const holders = await hook.read.tierHolders([3])
    assert.equal(holders.length, 1)
    assert.equal(holders[0], getAddress(wallets[0].account.address))
  })

  // --- Edge cases ---

  it('Should handle 100% discount', async function () {
    const { support, discountHook } = await deploy()
    await support.write.setHook([discountHook.address])
    await discountHook.write.setDiscount([1, 100])
    await support.write.support([walletClient.account.address, 0, 1], {
      value: 0n,
    })
    assert.equal(await support.read.totalSupply(), 1n)
  })

  it('Should emit MetadataUpdate on every call', async function () {
    const { support, hook } = await deploy()
    const ethCost = await readCost(support, [0, 1])
    await support.write.support([walletClient.account.address, 0, 1], {
      value: ethCost,
    })

    const hash = await support.write.support(
      [walletClient.account.address, 0, 1],
      { value: ethCost },
    )
    const receipt = await publicClient.getTransactionReceipt({ hash })
    const events = await publicClient.getContractEvents({
      address: support.address,
      abi: support.abi,
      eventName: 'MetadataUpdate',
      fromBlock: receipt.blockNumber,
      toBlock: receipt.blockNumber,
    })
    assert.equal(events.length, 1)
  })

  it('Should track multiple subscribers independently', async function () {
    const { support, hook } = await deploy()
    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })
    await support.write.support([otherWallet.account.address, 2, 1], {
      value: await readCost(support, [2, 1]),
      account: otherWallet.account,
    })

    assert.equal(await support.read.totalSupply(), 2n)
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      1n,
    )
    assert.equal(
      await support.read.subscription([otherWallet.account.address]),
      2n,
    )
  })

  // --- Owner grant ---

  it('Should allow owner to grant free subscription', async function () {
    const { support, hook } = await deploy()

    await support.write.grant([otherWallet.account.address, 3, 6, 0n])

    assert.equal(await support.read.totalSupply(), 1n)
    assert.equal(
      await support.read.subscription([otherWallet.account.address]),
      1n,
    )
    assert.equal(
      await support.read.ownerOf([1n]),
      getAddress(otherWallet.account.address),
    )

    const [tier, active] = await support.read.currentTier([1n])
    assert.equal(tier, 3)
    assert.equal(active, true)
  })

  it('Should allow owner to grant extension', async function () {
    const { support, hook } = await deploy()

    await support.write.grant([otherWallet.account.address, 0, 1, 0n])
    const firstExpiry = await support.read.expiresAt([1n])

    await support.write.grant([otherWallet.account.address, 0, 1, 0n])
    const secondExpiry = await support.read.expiresAt([1n])

    assert.equal(secondExpiry, firstExpiry + 30n * 24n * 60n * 60n)
    assert.equal(await support.read.totalSupply(), 1n)
  })

  it('Should reject non-owner grant', async function () {
    const { support, hook } = await deploy()

    await assert.rejects(
      support.write.grant([otherWallet.account.address, 0, 1, 0n], {
        account: otherWallet.account,
      }),
      /OwnableUnauthorizedAccount/,
    )
  })

  // --- Grant: startAt ---

  it('Should grant with future startAt', async function () {
    const { support } = await deploy()
    const block = await publicClient.getBlock()
    const futureStart = block.timestamp + 86400n // 1 day from now

    await support.write.grant([otherWallet.account.address, 2, 3, futureStart])

    const tokenId = await support.read.subscription([
      otherWallet.account.address,
    ])
    assert.equal(await support.read.startedAt([tokenId]), futureStart)

    const segs = await support.read.tierPeriods([tokenId])
    assert.equal(segs[0].startedAt, futureStart)

    // Expiry is based on future start + 3 months
    const expires = await support.read.expiresAt([tokenId])
    assert.equal(expires, futureStart + 3n * 30n * 24n * 60n * 60n)
  })

  it('Should grant with past startAt (backdating)', async function () {
    const { support } = await deploy()
    const block = await publicClient.getBlock()
    const pastStart = block.timestamp - 30n * 24n * 60n * 60n // 1 month ago

    await support.write.grant([otherWallet.account.address, 0, 3, pastStart])

    const tokenId = await support.read.subscription([
      otherWallet.account.address,
    ])
    assert.equal(await support.read.startedAt([tokenId]), pastStart)

    // Expiry is pastStart + 3 months = ~2 months from now
    const expires = await support.read.expiresAt([tokenId])
    assert.equal(expires, pastStart + 3n * 30n * 24n * 60n * 60n)
  })

  it('Should ignore startAt on grant extension (not new)', async function () {
    const { support } = await deploy()
    await support.write.grant([otherWallet.account.address, 0, 1, 0n])

    const firstExpiry = await support.read.expiresAt([1n])
    const firstStart = await support.read.startedAt([1n])

    // Extend with a startAt — should be ignored, expiry extends from current
    await support.write.grant([otherWallet.account.address, 0, 1, 9999999999n])

    assert.equal(await support.read.startedAt([1n]), firstStart) // unchanged
    assert.equal(
      await support.read.expiresAt([1n]),
      firstExpiry + 30n * 24n * 60n * 60n,
    )
  })

  // --- Grant vs hook ---

  it('Should grant bypassing beforeSubscribe but still notifying hook', async function () {
    const { support, hook } = await deploy()

    await hook.write.setMaxSlots([2, 1])
    const cost2 = await readCost(support, [2, 1])

    // Fill the slot
    await support.write.support([walletClient.account.address, 2, 1], {
      value: cost2,
    })

    // support() is blocked by beforeSubscribe
    await assert.rejects(
      support.write.support([otherWallet.account.address, 2, 1], {
        value: cost2,
        account: otherWallet.account,
      }),
      /SubscriptionBlocked/,
    )

    // grant() skips beforeSubscribe but onSubscribe still tracks state — reverts if full
    await assert.rejects(
      support.write.grant([otherWallet.account.address, 2, 1, 0n]),
      /TierFull/,
    )

    // Owner increases capacity, then grant works
    await hook.write.setMaxSlots([2, 2])
    await support.write.grant([otherWallet.account.address, 2, 1, 0n])
    assert.equal(await support.read.totalSupply(), 2n)

    const [tier, active] = await support.read.currentTier([2n])
    assert.equal(tier, 2)
    assert.equal(active, true)
  })

  // --- Grant tier change ---

  it('Should grant tier change without price conversion', async function () {
    const { support } = await deploy()

    // Grant tier 2 ($25/mo) for 2 months
    await support.write.grant([otherWallet.account.address, 2, 2, 0n])
    const expiryBefore = await support.read.expiresAt([1n])

    // Grant tier change to tier 0 ($5/mo) with 1 month — should NOT convert remaining time
    await support.write.grant([otherWallet.account.address, 0, 1, 0n])
    const expiryAfter = await support.read.expiresAt([1n])

    // Expiry is simply old expiry + 1 month (no 5x conversion like support() does)
    assert.equal(expiryAfter, expiryBefore + 30n * 24n * 60n * 60n)

    const [tier] = await support.read.currentTier([1n])
    assert.equal(tier, 0)
  })

  it('Should grant tier change with duration 0', async function () {
    const { support } = await deploy()

    await support.write.grant([otherWallet.account.address, 0, 2, 0n])
    const expiryBefore = await support.read.expiresAt([1n])

    // Change tier only, no extension
    await support.write.grant([otherWallet.account.address, 2, 0, 0n])
    const expiryAfter = await support.read.expiresAt([1n])

    assert.equal(expiryAfter, expiryBefore) // unchanged
    const [tier] = await support.read.currentTier([1n])
    assert.equal(tier, 2)
  })

  // --- Gifting ---

  it('Should allow gifting a subscription to another address', async function () {
    const { support, hook } = await deploy()
    const ethCost = await readCost(support, [2, 3])

    // walletClient pays, otherWallet receives
    await support.write.support([otherWallet.account.address, 2, 3], {
      value: ethCost,
    })

    assert.equal(await support.read.totalSupply(), 1n)
    assert.equal(
      await support.read.subscription([otherWallet.account.address]),
      1n,
    )
    assert.equal(
      await support.read.balanceOf([otherWallet.account.address]),
      1n,
    )
    assert.equal(
      await support.read.balanceOf([walletClient.account.address]),
      0n,
    )
    assert.equal(
      await support.read.ownerOf([1n]),
      getAddress(otherWallet.account.address),
    )

    const [tier, active] = await support.read.currentTier([1n])
    assert.equal(tier, 2)
    assert.equal(active, true)
  })

  it('Should reject third-party tier change', async function () {
    const wallets = await viem.getWalletClients()
    const { support, hook } = await deploy()

    // wallets[2] subscribes at tier 0
    await support.write.support([wallets[2].account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
      account: wallets[2].account,
    })

    // wallets[3] (not recipient, not owner) tries to upgrade — should fail
    await assert.rejects(
      support.write.support([wallets[2].account.address, 2, 1], {
        value: parseEther('1'),
        account: wallets[3].account,
      }),
      /TierChangeForbidden/,
    )

    // Third party extending at same tier is OK
    await support.write.support([wallets[2].account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
      account: wallets[3].account,
    })
  })

  it('Should allow recipient to change their own tier', async function () {
    const { support, hook } = await deploy()

    await support.write.support([otherWallet.account.address, 0, 2], {
      value: await readCost(support, [0, 2]),
      account: otherWallet.account,
    })

    // otherWallet upgrades themselves
    await support.write.support([otherWallet.account.address, 2, 1], {
      value: parseEther('1'),
      account: otherWallet.account,
    })

    const [tier] = await support.read.currentTier([1n])
    assert.equal(tier, 2)
  })

  it('Should reject support to zero address', async function () {
    const { support, hook } = await deploy()
    await assert.rejects(
      support.write.support(
        ['0x0000000000000000000000000000000000000000', 0, 1],
        {
          value: await readCost(support, [0, 1]),
        },
      ),
      /InvalidRecipient/,
    )
  })

  it('Should allow grant when oracle is stale', async function () {
    const { support, priceFeed, hook } = await deploy()

    // Make oracle stale
    await priceFeed.write.setStale()

    // Grant should work (skips oracle)
    await support.write.grant([otherWallet.account.address, 2, 3, 0n])

    const [tier, active] = await support.read.currentTier([1n])
    assert.equal(tier, 2)
    assert.equal(active, true)
  })

  // --- Renderer ---

  it('Should allow owner to update renderer', async function () {
    const { support, hook } = await deploy()
    const newRenderer = await viem.deployContract('SupportRenderer', [])
    await support.write.setRenderer([newRenderer.address])
    assert.equal(
      (await support.read.renderer()).toLowerCase(),
      newRenderer.address.toLowerCase(),
    )
  })

  it('Should reject non-owner setRenderer', async function () {
    const { support, hook } = await deploy()
    const newRenderer = await viem.deployContract('SupportRenderer', [])
    await assert.rejects(
      support.write.setRenderer([newRenderer.address], {
        account: otherWallet.account,
      }),
      /OwnableUnauthorizedAccount/,
    )
  })

  // --- Tier Badges ---

  it('Should render configured tier badge', async function () {
    const { support } = await deploy()
    await support.write.support([walletClient.account.address, 1, 1], {
      value: await readCost(support, [1, 1]),
    })

    const uri = await support.read.tokenURI([1n])
    const json = JSON.parse(Buffer.from(uri.split(',')[1], 'base64').toString())
    const svg = Buffer.from(json.image.split(',')[1], 'base64').toString()
    assert.ok(svg.includes('GOLD'))
    assert.ok(svg.includes('#A29C7A'))
  })

  it('Should render fallback badge for unconfigured tier', async function () {
    const { support } = await deploy()
    // Add tier 4 on the Support contract without configuring a badge
    await support.write.addTier([10000000000n])
    await support.write.grant([walletClient.account.address, 4, 1, 0n])

    const uri = await support.read.tokenURI([1n])
    const json = JSON.parse(Buffer.from(uri.split(',')[1], 'base64').toString())
    const svg = Buffer.from(json.image.split(',')[1], 'base64').toString()
    assert.ok(svg.includes('TIER 4'))
    assert.ok(svg.includes('#888'))
  })

  it('Should reject non-owner setTierBadge', async function () {
    const { renderer } = await deploy()
    await assert.rejects(
      renderer.write.setTierBadge([0, 'TEST', '#000', '#fff', 100], {
        account: otherWallet.account,
      }),
      /OwnableUnauthorizedAccount/,
    )
  })

  // --- Sale Start ---

  async function deployWithFutureSale() {
    const priceFeed = await viem.deployContract('MockPriceFeed', [ETH_USD])
    const renderer = await viem.deployContract('SupportRenderer', [])
    await configureBadges(renderer)
    const block = await publicClient.getBlock()
    const futureSaleStart = block.timestamp + 86400n // 1 day from chain time
    const support = await viem.deployContract('SupportToken', [
      walletClient.account.address,
      'TestProject',
      'TEST',
      priceFeed.address,
      tierPrices,
      futureSaleStart,
      '<path d="M0 0"/>',
      renderer.address,
    ])

    const discountHook = await viem.deployContract('DiscountHook', [
      discountMinMonths,
      discountPercentOff,
    ])
    await support.write.setHook([discountHook.address])

    return { support, priceFeed, renderer, discountHook, futureSaleStart }
  }

  it('Should revert support() before sale starts', async function () {
    const { support } = await deployWithFutureSale()

    await assert.rejects(
      support.write.support([walletClient.account.address, 0, 1], {
        value: parseEther('1'),
      }),
      /0x2d0a346e/, // SaleNotStarted()
    )
  })

  it('Should allow support() after sale starts', async function () {
    const { support, priceFeed } = await deployWithFutureSale()

    // Advance past sale start
    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [86401],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    const ethCost = await readCost(support, [0, 1])
    await support.write.support([walletClient.account.address, 0, 1], {
      value: ethCost,
    })
    assert.equal(await support.read.totalSupply(), 1n)
  })

  it('Should allow grant() before sale starts', async function () {
    const { support } = await deployWithFutureSale()

    await support.write.grant([otherWallet.account.address, 2, 3, 0n])
    assert.equal(await support.read.totalSupply(), 1n)
  })

  it('Should return correct saleStart and saleStarted', async function () {
    const { support, futureSaleStart } = await deployWithFutureSale()

    assert.equal(await support.read.saleStart(), futureSaleStart)
    assert.equal(await support.read.saleStarted(), false)

    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [86401],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })

    assert.equal(await support.read.saleStarted(), true)
  })

  it('Should allow owner to setSaleStart before sale', async function () {
    const { support, futureSaleStart } = await deployWithFutureSale()

    const newStart = futureSaleStart + 86400n
    await support.write.setSaleStart([newStart])
    assert.equal(await support.read.saleStart(), newStart)
  })

  it('Should revert setSaleStart after sale has started', async function () {
    const { support, hook } = await deploy() // saleStart = 0, already started

    await assert.rejects(
      support.write.setSaleStart([9999999999n]),
      /SaleAlreadyStarted|custom error/,
    )
  })

  it('Should reject non-owner setSaleStart', async function () {
    const { support } = await deployWithFutureSale()

    await assert.rejects(
      support.write.setSaleStart([9999999999n], {
        account: otherWallet.account,
      }),
      /OwnableUnauthorizedAccount/,
    )
  })

  // --- Gifting ---

  it('Should allow gifting an extension to existing subscription', async function () {
    const { support, hook } = await deploy()

    // Other wallet self-subscribes
    await support.write.support([otherWallet.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
      account: otherWallet.account,
    })
    const firstExpiry = await support.read.expiresAt([1n])

    // walletClient gifts an extension
    await support.write.support([otherWallet.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })
    const secondExpiry = await support.read.expiresAt([1n])

    assert.equal(secondExpiry, firstExpiry + 30n * 24n * 60n * 60n)
    assert.equal(await support.read.totalSupply(), 1n) // no new NFT
  })

  // --- Reentrancy through excess refund ---

  it('Should handle reentrancy through excess refund without corruption', async function () {
    const { support, hook } = await deploy()
    const attacker = await viem.deployContract('ReentrancyAttacker', [
      support.address,
    ])

    const ethCost = await readCost(support, [0, 1])

    // Fund attacker with enough ETH to cover cost + re-entrant extension
    await walletClient.sendTransaction({
      to: attacker.address,
      value: ethCost * 5n,
    })
    await attacker.write.attack([0, 1, 1], { value: ethCost * 3n })

    const tokenId = await support.read.subscription([attacker.address])
    assert.ok(tokenId > 0n)

    // State should be consistent despite re-entrant extension
    const started = await support.read.startedAt([tokenId])
    const expires = await support.read.expiresAt([tokenId])
    assert.ok(expires > started)

    const segs = await support.read.tierPeriods([tokenId])
    assert.equal(segs.length, 1)
    assert.equal(segs[0].tier, 0)
  })

  // --- Extreme duration values ---

  it('Should handle type(uint32).max duration via grant', async function () {
    const { support, hook } = await deploy()
    const maxDuration = 2 ** 32 - 1 // type(uint32).max = 4294967295

    await support.write.grant([otherWallet.account.address, 0, maxDuration, 0n])

    const tokenId = await support.read.subscription([
      otherWallet.account.address,
    ])
    assert.equal(tokenId, 1n)

    const expires = await support.read.expiresAt([tokenId])
    const started = await support.read.startedAt([tokenId])

    const uint64Max = (1n << 64n) - 1n
    const expectedDuration = BigInt(maxDuration) * 30n * 24n * 60n * 60n
    const expectedExpiry = started + expectedDuration

    if (expectedExpiry > uint64Max) {
      assert.equal(expires, uint64Max)
    } else {
      assert.equal(expires, expectedExpiry)
    }

    const [tier, active] = await support.read.currentTier([tokenId])
    assert.equal(tier, 0)
    assert.equal(active, true)
  })

  it('Should cap expiry at uint64.max on repeated large extensions', async function () {
    const { support, hook } = await deploy()
    const maxDuration = 2 ** 32 - 1

    await support.write.grant([otherWallet.account.address, 0, maxDuration, 0n])
    await support.write.grant([otherWallet.account.address, 0, maxDuration, 0n])
    await support.write.grant([otherWallet.account.address, 0, maxDuration, 0n])

    const tokenId = await support.read.subscription([
      otherWallet.account.address,
    ])
    const expires = await support.read.expiresAt([tokenId])
    const uint64Max = (1n << 64n) - 1n

    assert.ok(expires > 0n)
    assert.ok(expires <= uint64Max)

    // Should still be one token, not multiple
    assert.equal(await support.read.totalSupply(), 1n)
  })

  // --- Rapid tier switching ---

  it('Should handle many tier switches and render tokenURI', async function () {
    const { support, hook } = await deploy()

    await support.write.grant([walletClient.account.address, 0, 12, 0n])

    // Switch tiers via grant (avoids compounding cost from time conversion)
    const switches = [1, 2, 3, 2, 1, 0, 3] as const
    for (const tier of switches) {
      await support.write.grant([walletClient.account.address, tier, 1, 0n])
    }

    const segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 8)
    assert.equal(segs[0].tier, 0)
    assert.equal(segs[7].tier, 3)

    // tokenURI should render all 8 segments without reverting
    const uri = await support.read.tokenURI([1n])
    const json = JSON.parse(Buffer.from(uri.split(',')[1], 'base64').toString())
    assert.ok(json.attributes.find((a: any) => a.trait_type === 'Tier Period 8'))
    assert.equal(
      json.attributes.find((a: any) => a.trait_type === 'Tier').value,
      3,
    )
  })

  // --- maxSlots edge cases ---

  it('Should handle decreasing maxSlots below current holder count', async function () {
    const wallets = await viem.getWalletClients()
    const { support, hook } = await deploy()

    await hook.write.setMaxSlots([0, 3])
    const cost0 = await readCost(support, [0, 2])
    const cost0Single = await readCost(support, [0, 1])

    await support.write.support([wallets[0].account.address, 0, 2], {
      value: cost0,
      account: wallets[0].account,
    })
    await support.write.support([wallets[1].account.address, 0, 2], {
      value: cost0,
      account: wallets[1].account,
    })
    await support.write.support([wallets[2].account.address, 0, 2], {
      value: cost0,
      account: wallets[2].account,
    })
    assert.equal((await hook.read.tierHolders([0])).length, 3)

    // Decrease below current count — existing holders stay, new ones blocked
    await hook.write.setMaxSlots([0, 1])

    await assert.rejects(
      support.write.support([wallets[3].account.address, 0, 1], {
        value: cost0Single,
        account: wallets[3].account,
      }),
      /SubscriptionBlocked/,
    )

    await support.write.support([wallets[0].account.address, 0, 1], {
      value: cost0Single,
      account: wallets[0].account,
    })
  })

  it('Should allow new subscriber after increasing maxSlots past TierFull', async function () {
    const wallets = await viem.getWalletClients()
    const { support, hook } = await deploy()

    await hook.write.setMaxSlots([1, 1])
    const cost1 = await readCost(support, [1, 1])

    await support.write.support([wallets[0].account.address, 1, 1], {
      value: cost1,
      account: wallets[0].account,
    })

    await assert.rejects(
      support.write.support([wallets[1].account.address, 1, 1], {
        value: cost1,
        account: wallets[1].account,
      }),
      /SubscriptionBlocked/,
    )

    await hook.write.setMaxSlots([1, 2])

    await support.write.support([wallets[1].account.address, 1, 1], {
      value: cost1,
      account: wallets[1].account,
    })
    assert.equal((await hook.read.tierHolders([1])).length, 2)
  })

  // --- Concurrent subscriptions after transfer ---

  it('Should handle subscription lifecycle after transfer: Bob extends, Alice creates new', async function () {
    const { support, hook } = await deploy()

    await support.write.support([walletClient.account.address, 2, 2], {
      value: await readCost(support, [2, 2]),
    })
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      1n,
    )

    await support.write.transferFrom([
      walletClient.account.address,
      otherWallet.account.address,
      1n,
    ])
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      0n,
    )
    assert.equal(
      await support.read.subscription([otherWallet.account.address]),
      1n,
    )

    // Bob extends the transferred token
    const expiryBefore = await support.read.expiresAt([1n])
    await support.write.support([otherWallet.account.address, 2, 1], {
      value: await readCost(support, [2, 1]),
      account: otherWallet.account,
    })
    const expiryAfter = await support.read.expiresAt([1n])
    assert.equal(expiryAfter, expiryBefore + 30n * 24n * 60n * 60n)

    // Alice creates a fresh subscription (token 2)
    await support.write.support([walletClient.account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
    })
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      2n,
    )
    assert.equal(await support.read.totalSupply(), 2n)

    // Both tokens independently active
    const [tier1, active1] = await support.read.currentTier([1n])
    assert.equal(tier1, 2)
    assert.equal(active1, true)

    const [tier2, active2] = await support.read.currentTier([2n])
    assert.equal(tier2, 0)
    assert.equal(active2, true)
  })

  // --- Tier slot migration on transfer ---

  it('Should block new subscriber after transfer keeps tier full', async function () {
    const wallets = await viem.getWalletClients()
    const { support, hook } = await deploy()

    // Cap tier 2 at 1 slot
    await hook.write.setMaxSlots([2, 1])
    const cost2 = await readCost(support, [2, 3])

    // Alice subscribes at tier 2
    await support.write.support([wallets[0].account.address, 2, 3], {
      value: cost2,
      account: wallets[0].account,
    })
    assert.equal((await hook.read.activeTierHolders([2])).length, 1)

    // Alice transfers active NFT to Bob
    await support.write.transferFrom(
      [wallets[0].account.address, wallets[1].account.address, 1n],
      { account: wallets[0].account },
    )

    // Bob now holds the slot — tier is still full
    const active = await hook.read.activeTierHolders([2])
    assert.equal(active.length, 1)
    assert.equal(active[0], getAddress(wallets[1].account.address))

    // Charlie cannot subscribe — tier is full (cost() also reverts when blocked)
    await assert.rejects(
      support.write.support([wallets[2].account.address, 2, 1], {
        value: cost2,
        account: wallets[2].account,
      }),
      /SubscriptionBlocked/,
    )
  })

  it('Should migrate tier holder entry on transfer', async function () {
    const wallets = await viem.getWalletClients()
    const { support, hook } = await deploy()

    await hook.write.setMaxSlots([3, 2])
    const cost3 = await readCost(support, [3, 2])

    // Two holders in tier 3
    await support.write.support([wallets[0].account.address, 3, 2], {
      value: cost3,
      account: wallets[0].account,
    })
    await support.write.support([wallets[1].account.address, 3, 2], {
      value: cost3,
      account: wallets[1].account,
    })
    assert.equal((await hook.read.tierHolders([3])).length, 2)

    // wallets[0] transfers to wallets[2]
    await support.write.transferFrom(
      [wallets[0].account.address, wallets[2].account.address, 1n],
      { account: wallets[0].account },
    )

    // tierHolders should now contain wallets[1] and wallets[2], not wallets[0]
    const holders = await hook.read.tierHolders([3])
    assert.equal(holders.length, 2)
    const holderSet = new Set(holders.map((h: string) => h.toLowerCase()))
    assert.ok(!holderSet.has(wallets[0].account.address.toLowerCase()))
    assert.ok(holderSet.has(wallets[1].account.address.toLowerCase()))
    assert.ok(holderSet.has(wallets[2].account.address.toLowerCase()))
  })

  it('Should not modify tier holders when transferring expired token', async function () {
    const wallets = await viem.getWalletClients()
    const { support, priceFeed, hook } = await deploy()

    await hook.write.setMaxSlots([0, 2])

    await support.write.support([wallets[0].account.address, 0, 1], {
      value: await readCost(support, [0, 1]),
      account: wallets[0].account,
    })
    assert.equal((await hook.read.tierHolders([0])).length, 1)

    // Expire
    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [31 * 86400],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    // Transfer expired token — should not add wallets[1] to tier
    await support.write.transferFrom(
      [wallets[0].account.address, wallets[1].account.address, 1n],
      { account: wallets[0].account },
    )

    // Tier holders unchanged (wallets[0] still listed, stale)
    const holders = await hook.read.tierHolders([0])
    assert.equal(holders.length, 1)
    assert.equal(holders[0], getAddress(wallets[0].account.address))

    // No active holders
    assert.equal((await hook.read.activeTierHolders([0])).length, 0)
  })

  it('Should revert transfer to address that already holds a token (tier slots)', async function () {
    const wallets = await viem.getWalletClients()
    const { support, hook } = await deploy()

    await hook.write.setMaxSlots([2, 2])

    // Both wallets subscribe at tier 2
    await support.write.support([wallets[0].account.address, 2, 3], {
      value: await readCost(support, [2, 3]),
      account: wallets[0].account,
    })
    await support.write.support([wallets[1].account.address, 2, 3], {
      value: await readCost(support, [2, 3]),
      account: wallets[1].account,
    })

    // Transfer to wallets[1] who already has a token — reverts
    await assert.rejects(
      support.write.transferFrom(
        [wallets[0].account.address, wallets[1].account.address, 1n],
        { account: wallets[0].account },
      ),
      /OneTokenPerWallet/,
    )
  })

  it('Should allow Alice to resubscribe after transferring away her active token', async function () {
    const wallets = await viem.getWalletClients()
    const { support, hook } = await deploy()

    await hook.write.setMaxSlots([2, 2])
    const cost2 = await readCost(support, [2, 2])

    // Alice subscribes
    await support.write.support([wallets[0].account.address, 2, 2], {
      value: cost2,
      account: wallets[0].account,
    })
    assert.equal((await hook.read.tierHolders([2])).length, 1)

    // Transfer to Bob
    await support.write.transferFrom(
      [wallets[0].account.address, wallets[1].account.address, 1n],
      { account: wallets[0].account },
    )

    // Alice resubscribes — should work since she was removed from tier
    await support.write.support([wallets[0].account.address, 2, 1], {
      value: await readCost(support, [2, 1]),
      account: wallets[0].account,
    })

    const holders = await hook.read.tierHolders([2])
    assert.equal(holders.length, 2)
    const active = await hook.read.activeTierHolders([2])
    assert.equal(active.length, 2)
  })

  it('Should reset tierPeriods on re-subscribe after expiry', async function () {
    const { support, priceFeed, hook } = await deploy()

    // Subscribe tier 0, upgrade to tier 2
    await support.write.support([walletClient.account.address, 0, 2], {
      value: await readCost(support, [0, 2]),
    })
    await support.write.support([walletClient.account.address, 2, 1], {
      value: parseEther('1'),
    })

    let segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 2)

    // Expire
    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [120 * 86400],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    // Re-subscribe at tier 1
    await support.write.support([walletClient.account.address, 1, 1], {
      value: await readCost(support, [1, 1]),
    })

    // tierPeriods should be reset to single entry
    segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 1)
    assert.equal(segs[0].tier, 1)
  })

  // --- Invalid price ---

  it('Should reject deployment with zero tier price', async function () {
    const priceFeed = await viem.deployContract('MockPriceFeed', [ETH_USD])

    await assert.rejects(
      viem.deployContract('SupportToken', [
        walletClient.account.address,
        'TestProject',
        'TEST',
        priceFeed.address,
        [0n, 1000000000n, 2500000000n, 10000000000n],
        0n,
        '',
        zeroAddress,
      ]),
      /InvalidPrice/,
    )
  })
})

// --- Base Support (without tokens) ---

describe('BaseSupport', async function () {
  async function deployBase() {
    const priceFeed = await viem.deployContract('MockPriceFeed', [ETH_USD])
    const support = await viem.deployContract('MockSupport', [
      walletClient.account.address,
      'TestProject',
      'TEST',
      priceFeed.address,
      tierPrices,
      0n,
    ])

    const discountHook = await viem.deployContract('DiscountHook', [
      discountMinMonths,
      discountPercentOff,
    ])
    await support.write.setHook([discountHook.address])

    return { support, priceFeed }
  }

  it('Should create subscriptions with IDs but no NFTs', async function () {
    const { support } = await deployBase()
    const cost = await readCost(support, [0, 1])

    await support.write.support([walletClient.account.address, 0, 1], {
      value: cost,
    })

    assert.equal(await support.read.totalSupply(), 1n)
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      1n,
    )
    const segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 1)
    assert.equal(segs[0].tier, 0)
  })

  it('Should extend and change tiers without NFTs', async function () {
    const { support } = await deployBase()
    const cost = await readCost(support, [0, 1])

    await support.write.support([walletClient.account.address, 0, 1], {
      value: cost,
    })
    const firstExpiry = await support.read.expiresAt([1n])

    // Extend same tier
    await support.write.support([walletClient.account.address, 0, 1], {
      value: cost,
    })
    const secondExpiry = await support.read.expiresAt([1n])
    assert.equal(secondExpiry, firstExpiry + 30n * 24n * 60n * 60n)

    // Still only one subscription ID
    assert.equal(await support.read.totalSupply(), 1n)

    // Upgrade tier
    await support.write.support([walletClient.account.address, 2, 1], {
      value: parseEther('1'),
    })
    const segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 2)
    assert.equal(segs[1].tier, 2)
  })

  it('Should track multiple subscribers independently', async function () {
    const { support } = await deployBase()
    const cost = await readCost(support, [0, 1])

    await support.write.support([walletClient.account.address, 0, 1], {
      value: cost,
    })
    await support.write.support([otherWallet.account.address, 1, 1], {
      value: await readCost(support, [1, 1]),
      account: otherWallet.account,
    })

    assert.equal(await support.read.totalSupply(), 2n)
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      1n,
    )
    assert.equal(
      await support.read.subscription([otherWallet.account.address]),
      2n,
    )
  })

  it('Should reuse subscription ID after expiry', async function () {
    const { support, priceFeed } = await deployBase()
    const cost = await readCost(support, [0, 1])

    await support.write.support([walletClient.account.address, 0, 1], {
      value: cost,
    })
    assert.equal(await support.read.totalSupply(), 1n)

    // Fast-forward past expiry and refresh oracle
    await publicClient.request({
      method: 'evm_increaseTime' as any,
      params: [31 * 86400],
    })
    await publicClient.request({ method: 'evm_mine' as any, params: [] })
    await priceFeed.write.setPrice([ETH_USD])

    // Re-subscribe — reuses same ID
    await support.write.support([walletClient.account.address, 0, 1], {
      value: cost,
    })
    assert.equal(await support.read.totalSupply(), 1n)
    assert.equal(
      await support.read.subscription([walletClient.account.address]),
      1n,
    )

    // tierPeriods reset
    const segs = await support.read.tierPeriods([1n])
    assert.equal(segs.length, 1)
    assert.equal(segs[0].tier, 0)
  })
})
