import { index, onchainTable, relations } from 'ponder'

export const supporter = onchainTable(
  'supporter',
  (t) => ({
    address: t.hex().primaryKey(),
    tier: t.integer().notNull(),
    subscriptionId: t.bigint().notNull(),
    startedAt: t.bigint().notNull(),
    expiresAt: t.bigint().notNull(),
    totalPaid: t.bigint().notNull(),
  }),
  (table) => ({
    tierIdx: index().on(table.tier),
  }),
)

export const subscription = onchainTable(
  'subscription',
  (t) => ({
    subscriptionId: t.bigint().primaryKey(),
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
)

export const supportEvent = onchainTable(
  'support_event',
  (t) => ({
    id: t.text().primaryKey(),
    subscriptionId: t.bigint().notNull(),
    tier: t.integer().notNull(),
    duration: t.integer().notNull(),
    paid: t.bigint().notNull(),
    startedAt: t.bigint().notNull(),
    expiresAt: t.bigint().notNull(),
    block: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (table) => ({
    subscriptionIdx: index().on(table.subscriptionId),
    tierIdx: index().on(table.tier),
  }),
)

export const subscriptionRelations = relations(subscription, ({ many }) => ({
  events: many(supportEvent),
}))

export const supportEventRelations = relations(supportEvent, ({ one }) => ({
  subscription: one(subscription, {
    fields: [supportEvent.subscriptionId],
    references: [subscription.subscriptionId],
  }),
}))
