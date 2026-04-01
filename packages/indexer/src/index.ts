import { ponder } from 'ponder:registry'
import { supporter, subscription, supportEvent } from 'ponder:schema'

ponder.on('Support:Transfer', async ({ event, context }) => {
  const { from, to, tokenId } = event.args

  if (from === '0x0000000000000000000000000000000000000000') {
    await context.db
      .insert(subscription)
      .values({
        tokenId,
        owner: to,
        subscriber: to,
        startedAt: event.block.timestamp,
        expiresAt: 0n,
        totalPaid: 0n,
      })
      .onConflictDoNothing()
  } else {
    await context.db.update(subscription, { tokenId }).set({ owner: to })
  }
})

ponder.on('Support:Supported', async ({ event, context }) => {
  const {
    supporter: address,
    tier,
    tokenId,
    duration,
    paid,
    expiresAt,
  } = event.args

  await context.db.insert(supportEvent).values({
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    tokenId,
    tier,
    duration,
    paid,
    expiresAt: BigInt(expiresAt),
    block: event.block.number,
    timestamp: event.block.timestamp,
  })

  await context.db
    .insert(subscription)
    .values({
      tokenId,
      owner: address,
      subscriber: address,
      startedAt: event.block.timestamp,
      expiresAt: BigInt(expiresAt),
      totalPaid: paid,
    })
    .onConflictDoUpdate((row) => ({
      subscriber: address,
      expiresAt: BigInt(expiresAt),
      totalPaid: row.totalPaid + paid,
    }))

  // Mark address as supporter with current tier
  await context.db
    .insert(supporter)
    .values({
      address,
      tier,
      tokenId,
      expiresAt: BigInt(expiresAt),
      totalPaid: paid,
    })
    .onConflictDoUpdate((row) => ({
      tier,
      tokenId,
      expiresAt: BigInt(expiresAt),
      totalPaid: row.totalPaid + paid,
    }))
})
