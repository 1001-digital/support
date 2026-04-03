```
       ·       ·   ·     ·
         ·   ·       · ·
           · · · · · ·
            · · · · ·
             ·······
              ─────
            ─────────
          ─────────────
       ───────────────────
```

# Support

A tiered support system on the world computer.

Support is a minimal contract for recurring ETH-based patronage. Supporters choose a tier, pay in ETH (priced via Chainlink USD oracle), and receive a tradeable ERC-721 NFT representing their subscription. Subscriptions can be upgraded, downgraded, extended, or gifted. The NFT carries fully on-chain SVG metadata built dynamically from the subscription state.

## Contract

The core is [`Support.sol`](packages/contract/contracts/Support.sol), an abstract contract extended by [`SupportToken.sol`](packages/contract/contracts/SupportToken.sol) which adds ERC-721 token representation via [`WithSupportTokens`](packages/contract/contracts/extensions/WithSupportTokens.sol).

### `support`

Subscribe an address at a given tier for a number of months. The payer (`msg.sender`) pays; the subscription and NFT go to the recipient. Third parties can extend or start subscriptions, but only the recipient (or owner) may change tiers.

```solidity
function support(address recipient, uint8 tier, uint32 duration) external payable
```

Prices are set in USD and converted to ETH at the current Chainlink rate. Excess ETH is refunded.

### `grant`

Owner can grant free subscriptions with an optional custom start time.

```solidity
function grant(address recipient, uint8 tier, uint32 duration, uint64 startAt) external onlyOwner
```

### `estimate`

Get the ETH cost and adjusted duration for a given tier, duration, and supporter (accounts for hooks).

```solidity
function estimate(uint8 tier, uint32 duration, address supporter) external view returns (uint256 ethCost, uint32 adjustedDuration)
```

### Subscriptions

Each subscription has a unique ID. An address can only have one active subscription at a time, tracked by `subscription[address]`.

Subscription data is stored per ID:

```solidity
struct SubscriptionData {
    uint64 createdAt;
    uint64 startedAt;
    uint64 expiresAt;
}
```

Tier changes are recorded as a history of `TierPeriod { tier, startedAt }` segments.

### Tier Changes

- **Same tier**: extends the expiry. No new segment.
- **Upgrade**: tier switches immediately. Remaining time is converted at the rate ratio (`remaining * oldPrice / newPrice`), then new duration is added. If the result is under 30 days, extra is charged to guarantee the minimum.
- **Downgrade**: tier switches immediately. Remaining time converts to more time at the lower rate. `duration = 0` is valid for a pure tier switch with no extension.

### Gifting

Anyone can gift a subscription or extension by passing a different `recipient` to `support()`. Third parties can only extend at the same tier — only the recipient or owner may change an active subscription's tier.

### NFT

A standard ERC-721 is minted on first support (one per wallet via `OnePerWallet`). Tokens are fully transferable — the subscription travels with the NFT. When transferred, the sender loses the active subscription and the receiver inherits it. After a subscription expires, calling `support()` again mints a new NFT — the old one stays in the wallet as a historical record.

Token metadata is fully on-chain via a pluggable `ISupportRenderer`. The default `SupportRenderer` generates a `data:application/json;base64` URI with a dynamically built SVG showing the project name, supporter address, tier badge, subscription status, and duration.

ERC-4906 `MetadataUpdate` is emitted on every subscription change so marketplaces refresh.

### Hooks

Subscription behavior can be customized via the `ISubscriptionHook` interface, set with `setHook()`. Hooks can adjust pricing, duration, start time, block subscriptions, and react to tier changes.

```solidity
interface ISubscriptionHook {
    function beforeSubscribe(uint8 tier, uint32 duration, uint256 baseUSD, address supporter, bool isNew, uint8 previousTier) external view returns (Adjustments memory);
    function canSubscribe(uint8 tier, address supporter) external view returns (bool);
    function onSubscribe(uint8 tier, address supporter) external;
    function onRelease(uint8 tier, address supporter) external;
}
```

Built-in hooks:

| Hook | Description |
| --- | --- |
| [`DiscountHook`](packages/contract/contracts/hooks/DiscountHook.sol) | Configurable bulk discount (min months + percent off) |
| [`MaxSlotsHook`](packages/contract/contracts/hooks/MaxSlotsHook.sol) | Limits active subscribers per tier |
| [`EvmNowSupporterHook`](packages/contract/contracts/hooks/EvmNowSupporterHook.sol) | 20% discount for 12+ months, blocks partner tier |

### Owner Functions

| Function | Contract | Description |
| --- | --- | --- |
| `setTierPrice(tier, priceUSD)` | Support | Update a tier's monthly USD price |
| `addTier(priceUSD)` | Support | Add a new tier |
| `setHook(hook)` | Support | Set the subscription hook (address(0) to disable) |
| `withdraw()` | Support | Withdraw all collected ETH |
| `setLogo(logo)` | WithSupportTokens | Update the logo SVG content |
| `setRenderer(renderer)` | WithSupportTokens | Update the metadata renderer contract |
| `transferOwnership(newOwner)` | Support | Transfer contract ownership (two-step) |

### Events

```solidity
event Supported(address indexed supporter, uint8 indexed tier, uint256 indexed subscriptionId, uint32 duration, uint256 paid, uint64 startedAt, uint64 expiresAt)
event TierPriceUpdated(uint8 indexed tier, uint128 priceUSD)
event HookUpdated(address hook)
event Withdrawal(address indexed to, uint256 amount)
event MetadataUpdate(uint256 tokenId)
```

## Packages

Monorepo managed with [pnpm workspaces](https://pnpm.io/workspaces).

| Package | Description |
| --- | --- |
| [`packages/contract`](packages/contract) | Solidity contract, tests, and deployment |
| [`packages/indexer`](packages/indexer) | Ponder-based indexer for subscriptions and events |

### Contract

Built with [Hardhat 3](https://hardhat.org/) and [viem](https://viem.sh/).

```shell
cd packages/contract
npx hardhat test
```

### Indexer

A [Ponder](https://ponder.sh/) indexer that watches `Supported` and `Transfer` events, maintaining a queryable database of supporters, subscriptions, and events. Exposes GraphQL and SQL APIs.

## Setup

```shell
pnpm install
```

## License

[MIT](LICENSE)
