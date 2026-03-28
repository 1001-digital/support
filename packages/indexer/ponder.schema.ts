import { index, onchainTable, relations } from "ponder";

export const subscription = onchainTable(
  "subscription",
  (t) => ({
    tokenId: t.bigint().primaryKey(),
    owner: t.hex().notNull(),
    subscriber: t.hex().notNull(),
    startedAt: t.bigint().notNull(),
    expiresAt: t.bigint().notNull(),
    totalPaid: t.bigint().notNull(),
  }),
  (table) => ({
    ownerIdx: index().on(table.owner),
    subscriberIdx: index().on(table.subscriber),
  }),
);

export const segment = onchainTable(
  "segment",
  (t) => ({
    id: t.text().primaryKey(),
    tokenId: t.bigint().notNull(),
    index: t.integer().notNull(),
    tier: t.integer().notNull(),
    startedAt: t.bigint().notNull(),
    block: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (table) => ({
    tokenIdx: index().on(table.tokenId),
    tierIdx: index().on(table.tier),
  }),
);

export const subscriptionRelations = relations(subscription, ({ many }) => ({
  segments: many(segment),
}));

export const segmentRelations = relations(segment, ({ one }) => ({
  subscription: one(subscription, {
    fields: [segment.tokenId],
    references: [subscription.tokenId],
  }),
}));
