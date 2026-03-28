import { ponder } from "ponder:registry";
import { subscription, segment } from "ponder:schema";

let segmentCounters: Record<string, number> = {};

ponder.on("Support:Transfer", async ({ event, context }) => {
  const { from, to, tokenId } = event.args;
  const zeroAddr = "0x0000000000000000000000000000000000000000";

  if (from === zeroAddr) {
    // Mint — create subscription record
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

    segmentCounters[tokenId.toString()] = 0;
  } else {
    // Transfer — update owner
    await context.db
      .update(subscription, { tokenId })
      .set({ owner: to });
  }
});

ponder.on("Support:Supported", async ({ event, context }) => {
  const { supporter, tier, tokenId, paid, expiresAt } = event.args;

  const key = tokenId.toString();
  const idx = segmentCounters[key] ?? 0;
  segmentCounters[key] = idx + 1;

  await context.db
    .insert(segment)
    .values({
      id: `${tokenId}-${idx}`,
      tokenId,
      index: idx,
      tier,
      startedAt: event.block.timestamp,
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
    .onConflictDoUpdate(() => ({
      subscriber: supporter,
      expiresAt: BigInt(expiresAt),
      totalPaid: paid,
    }));
});
