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

Support is a minimal contract for recurring ETH-based patronage. Supporters choose one of four tiers, pay in ETH (priced via Chainlink USD oracle), and receive a tradeable ERC-721 NFT representing their subscription. Subscriptions can be upgraded, downgraded, extended, or gifted. The NFT carries fully on-chain SVG metadata built dynamically from the subscription state.

## Contract

The core is a single Solidity contract: [`Support.sol`](packages/contract/contracts/Support.sol).

### `support`

Subscribe an address at a given tier for a number of months. The payer (`msg.sender`) pays; the subscription and NFT go to the recipient.

```solidity
function support(address recipient, uint8 tier, uint32 duration) external payable
```

Prices are set in USD (8 decimals) and converted to ETH at the current Chainlink rate. If duration meets the minimum month threshold, a bulk discount is applied. Excess ETH is refunded.

### `grant`

Owner can grant free subscriptions to any address. Grants bypass the oracle entirely.

```solidity
function grant(address recipient, uint8 tier, uint32 duration) external onlyOwner
```

### Subscriptions

Each subscription is an NFT (token ID). An address can hold multiple NFTs but only one active subscription at a time, tracked by `activeToken[address]`.

Subscription data is stored per token:

```solidity
mapping(uint256 => uint64) public startedAt;
mapping(uint256 => uint64) public expiresAt;
mapping(uint256 => Segment[]) internal _segments;
```

### Tier Changes

Tier changes are immediate.

- **Same tier**: extends the expiry. No new segment.
- **Upgrade**: tier switches immediately. The supporter pays the price difference for remaining time plus the cost of new months. Expiry extends from the current expiry.
- **Downgrade**: tier switches immediately. Remaining time at the old rate converts to more time at the new lower rate (`remaining * oldPrice / newPrice`). The supporter pays only for new months.

Each tier change pushes a new `Segment { tier, startedAt }` recording when the switch happened. The effective duration of each segment is derived from the gap to the next segment (or `expiresAt` for the last).

### Gifting

Anyone can gift a subscription or extension by passing a different `recipient` to `support()`. Third parties can only extend at the same tier — only the recipient or owner may change an active subscription's tier.

### NFT

A standard ERC-721 is minted on first support. Tokens are fully transferable — the subscription travels with the NFT. When a token is transferred, the sender loses the active subscription and the receiver inherits it (unless they already have one).

Token metadata is fully on-chain. `tokenURI` returns a `data:application/json;base64` URI with a dynamically built SVG:

- **Top left**: project name
- **Top right**: subscriber address (ENS name if available, otherwise short hex `0x1234...5678`)
- **Center**: logo + tier badge
- **Bottom left**: `DAY X` (days since mint)
- **Bottom center**: `ACTIVE` or `EXPIRED`
- **Bottom right**: duration in days

The SVG uses black on white, monospace, all uppercase. Tier badges are hardcoded in the contract source. The owner sets the logo via `setLogo`, which is rendered alongside each tier's badge. ENS reverse resolution is attempted on-chain — falls back to short hex on chains without ENS.

- **Active tokens**: show the current tier's badge
- **Expired tokens**: show the last active tier's badge

ERC-4906 `MetadataUpdate` is emitted on every `support()` call so marketplaces refresh when tier or dates change.

After a subscription expires, calling `support()` again mints a new NFT. The old one stays in the wallet as a historical record.

### Tier Slot Limits

The owner can limit how many active subscribers a tier allows:

```solidity
function setMaxSlots(uint8 tier, uint16 max) external onlyOwner
```

Default is 0 (unlimited). When a limit is set, slots are freed lazily — expired or downgraded holders are replaced when someone new subscribes.

### Events

Every support action emits:

```solidity
event Supported(
    address indexed supporter,
    uint8 indexed tier,
    uint256 indexed tokenId,
    uint32 duration,
    uint256 paid,
    uint64 expiresAt
)
```

All three fields are indexed for efficient log filtering by supporter, tier, or token.

### Owner Functions

| Function | Description |
|---|---|
| `grant(recipient, tier, duration)` | Grant a free subscription |
| `setTierPrice(tier, priceUSD)` | Update a tier's monthly USD price |
| `setDiscount(minMonths, percentOff)` | Configure bulk discount (e.g. 12 months, 20% off) |
| `setMaxSlots(tier, max)` | Limit active subscribers per tier (0 = unlimited) |
| `setProjectName(name)` | Update the project name |
| `setProjectSymbol(symbol)` | Update the ERC-721 symbol |
| `setLogo(logo)` | Update the logo SVG content |
| `withdraw()` | Withdraw all collected ETH |
| `transferOwnership(newOwner)` | Transfer contract ownership |

## Packages

This is a monorepo managed with [pnpm workspaces](https://pnpm.io/workspaces).

| Package | Description | Status |
|---|---|---|
| [`packages/contract`](packages/contract) | Solidity contract, tests, and deployment | Ready |
| [`packages/indexer`](packages/indexer) | Ponder-based indexer for subscriptions and events | Ready |

### Contract

Built with [Hardhat 3](https://hardhat.org/) and [viem](https://viem.sh/).

```shell
cd packages/contract
npx hardhat test
```

### Indexer

A [Ponder](https://ponder.sh/) indexer that watches for `Supported` and `Transfer` events, maintaining a queryable database of subscriptions (with owner, subscriber, segments, and dates) and a full event log. Exposes GraphQL and SQL APIs.

## Setup

```shell
pnpm install
```

## License

[MIT](LICENSE)
