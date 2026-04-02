import { ponder } from 'ponder:registry'
import { supporter, subscription, supportEvent } from 'ponder:schema'

ponder.on('Support:Transfer', async ({ event, context }) => {
  const { from, to, tokenId } = event.args

  if (from === '0x0000000000000000000000000000000000000000') {
    await context.db
      .insert(subscription)
      .values({
        subscriptionId: tokenId,
        owner: to,
        subscriber: to,
        startedAt: event.block.timestamp,
        expiresAt: 0n,
        totalPaid: 0n,
      })
      .onConflictDoNothing()
  } else {
    await context.db.update(subscription, { subscriptionId: tokenId }).set({ owner: to })
  }
})

ponder.on('Support:Supported', async ({ event, context }) => {
  const {
    supporter: address,
    tier,
    subscriptionId,
    duration,
    paid,
    startedAt,
    expiresAt,
  } = event.args

  await context.db.insert(supportEvent).values({
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    subscriptionId,
    tier,
    duration,
    paid,
    startedAt,
    expiresAt,
    block: event.block.number,
    timestamp: event.block.timestamp,
  })

  await context.db
    .insert(subscription)
    .values({
      subscriptionId,
      owner: address,
      subscriber: address,
      startedAt,
      expiresAt,
      totalPaid: paid,
    })
    .onConflictDoUpdate((row) => ({
      subscriber: address,
      expiresAt,
      totalPaid: row.totalPaid + paid,
    }))

  await context.db
    .insert(supporter)
    .values({
      address,
      tier,
      subscriptionId,
      startedAt,
      expiresAt,
      totalPaid: paid,
    })
    .onConflictDoUpdate((row) => ({
      tier,
      subscriptionId,
      expiresAt,
      totalPaid: row.totalPaid + paid,
    }))
})
