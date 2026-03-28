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

export const supportEvent = onchainTable(
  "support_event",
  (t) => ({
    id: t.text().primaryKey(),
    tokenId: t.bigint().notNull(),
    tier: t.integer().notNull(),
    duration: t.integer().notNull(),
    paid: t.bigint().notNull(),
    expiresAt: t.bigint().notNull(),
    block: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (table) => ({
    tokenIdx: index().on(table.tokenId),
    tierIdx: index().on(table.tier),
  }),
);

export const subscriptionRelations = relations(subscription, ({ many }) => ({
  events: many(supportEvent),
}));

export const supportEventRelations = relations(supportEvent, ({ one }) => ({
  subscription: one(subscription, {
    fields: [supportEvent.tokenId],
    references: [subscription.tokenId],
  }),
}));
