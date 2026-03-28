import { ponder } from "ponder:registry";
import { subscription, supportEvent } from "ponder:schema";

ponder.on("Support:Transfer", async ({ event, context }) => {
  const { from, to, tokenId } = event.args;

  if (from === "0x0000000000000000000000000000000000000000") {
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
      .onConflictDoNothing();
  } else {
    await context.db
      .update(subscription, { tokenId })
      .set({ owner: to });
  }
});

ponder.on("Support:Supported", async ({ event, context }) => {
  const { supporter, tier, tokenId, duration, paid, expiresAt } = event.args;

  await context.db
    .insert(supportEvent)
    .values({
      id: `${event.transaction.hash}-${event.log.logIndex}`,
      tokenId,
      tier,
      duration,
      paid,
      expiresAt: BigInt(expiresAt),
      block: event.block.number,
      timestamp: event.block.timestamp,
    });

  await context.db
    .insert(subscription)
    .values({
      tokenId,
      owner: supporter,
      subscriber: supporter,
      startedAt: event.block.timestamp,
      expiresAt: BigInt(expiresAt),
      totalPaid: paid,
    })
    .onConflictDoUpdate((row) => ({
      subscriber: supporter,
      expiresAt: BigInt(expiresAt),
      totalPaid: row.totalPaid + paid,
    }));
});
