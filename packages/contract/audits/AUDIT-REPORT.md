# Security Audit Report

**Project**: Support (Tiered Subscription System)
**Date**: 2026-04-02
**Auditor**: Claude Opus 4.6 (automated, 6 parallel specialist agents)
**Scope**: All contracts in `packages/contract/contracts/` (excluding mocks)
**Compiler**: Solidity ^0.8.28

---

## Executive Summary

The Support protocol implements a tiered subscription system where users pay ETH (priced via Chainlink USD oracle) for time-based subscriptions, optionally represented as ERC-721 tokens. The architecture is clean: an abstract `Support` base contract handles subscription logic, `WithSupportTokens` adds NFT representation, and a hook system allows extensible behavior (discounts, slot limits).

**No Critical vulnerabilities were found.** The contract correctly implements checks-effects-interactions in `support()`, uses `Ownable2Step` for ownership safety, validates oracle data, and prevents zero-price tiers.

The most significant findings are two **High** severity DoS vectors in the hook system. The remaining findings are **Medium** (10) and **Low** (17) severity issues related to precision loss, oracle robustness, access control centralization, and ERC-721 edge cases.

### Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 10 |
| Low | 17 |
| Info | 14 |

---

## High Severity

### [H-1] Unbounded Loops in MaxSlotsHook Can DoS Subscriptions
**Sources**: DOS-1, DOS-2, G-8
**Location**: `MaxSlotsHook.sol:60-67` (`onSubscribe`), `MaxSlotsHook.sol:125-129` (`_canSubscribe`)

When a tier is full, both `onSubscribe()` and `_canSubscribe()` iterate ALL holders, making 2 cross-contract calls per iteration via `_isActiveOnTier()`. If `maxSlots` is set to 500+, the loop costs 2.5M-5M+ gas, risking block gas limit exhaustion. Since these are called within `support()`, the entire subscription transaction reverts.

**Recommendation**: Cap `maxSlots` to a safe upper bound (e.g., 100) in `setMaxSlots()`, or replace the linear scan with a counter-based approach tracking active holders.

### [H-2] Reverting Hook Can Permanently DoS All Subscriptions and Transfers
**Sources**: DOS-4, G-5, DOS-10
**Location**: `Support.sol:268-274` (`_notifyHook`), `Support.sol:338-346` (`_beforeSubscribe`), `WithSupportTokens.sol:79-83` (`_update`)

All hook calls (`beforeSubscribe`, `onSubscribe`, `onRelease`) are unwrapped -- a reverting hook blocks all subscriptions via `support()`, all grants via `grant()`, and all NFT transfers of active subscriptions via `_update()`. The owner can recover by calling `setHook(address(0))`, but there is a DoS window.

**Recommendation**: Wrap `onSubscribe` and `onRelease` in `try/catch` (they are post-state-change notifications). `beforeSubscribe` must remain reverting since it returns pricing data.

---

## Medium Severity

### [M-1] Reentrancy in `support()` via Excess ETH Refund
**Sources**: G-1
**Location**: `Support.sol:154-158`

The excess ETH refund uses `msg.sender.call{value: excess}("")` after all state updates but without a `nonReentrant` guard. Currently safe due to CEI pattern, but latent risk if code evolves or hooks introduce shared mutable state.

**Recommendation**: Add OpenZeppelin `ReentrancyGuard` to `support()`.

### [M-2] Division Truncation in `_changeTier()` Rounds Against Subscriber
**Sources**: PM-1, G-7
**Location**: `Support.sol:286`

`uint256(remaining) * oldPrice / newPrice` truncates, causing subscribers to lose fractional time on tier changes. Loss is proportional to `newPrice` -- up to ~10 USD-seconds worth per change with 8-decimal prices.

**Recommendation**: Round up in favor of subscriber: `(uint256(remaining) * oldPrice + newPrice - 1) / newPrice`, or document as intended.

### [M-3] `_usdToEth` Can Return Zero for Small Non-Zero USD Amounts
**Sources**: PM-7
**Location**: `HasPriceFeed.sol:41`, `Support.sol:348`

If a hook returns a very small but non-zero `adjustedUSD`, `usdAmount * 1e18 / price` can round to zero, allowing a free subscription that bypasses the `adjustedUSD == 0` check in `_baseCost`.

**Recommendation**: Add `require(cost > 0, "Cost rounds to zero")` after `_usdToEth` in `_baseCost`.

### [M-4] OnePerWallet Blocks Transfers to Expired-Token Holders
**Sources**: NFT-4
**Location**: `OnePerWallet.sol`, `WithSupportTokens.sol:66-87`

Tokens are never burned. Once a subscription expires, the holder still owns the token and cannot receive a transferred subscription from anyone else due to the one-per-wallet constraint. They must first transfer their expired token away.

**Recommendation**: Add a `burn()` function for expired tokens, or document as intended behavior.

### [M-5] No Chainlink `minAnswer`/`maxAnswer` Circuit Breaker Check
**Sources**: O-2
**Location**: `HasPriceFeed.sol:35-41`

During extreme market events, Chainlink reports capped prices at circuit breaker bounds. The protocol would then misprice subscriptions -- e.g., if ETH crashes below `minAnswer`, subscribers pay less ETH value than intended.

**Recommendation**: Read the aggregator's `minAnswer`/`maxAnswer` and validate, or monitor off-chain.

### [M-6] Unhandled Chainlink Revert Causes Complete Subscription DoS
**Sources**: O-7
**Location**: `HasPriceFeed.sol:36-37`

`priceFeed.latestRoundData()` is not wrapped in `try/catch`. If Chainlink access-controls or deprecates the feed, all `support()` and `estimate()` calls revert. The owner can recover via `setPriceFeed()` but there is a DoS window.

**Recommendation**: Wrap in `try/catch` with a cached fallback price, or accept as known limitation given `setPriceFeed()` escape hatch.

### [M-7] Owner Can Instantly Change Critical Parameters Without Timelock
**Sources**: AC-1
**Location**: `Support.sol:218` (`setTierPrice`), `Support.sol:233` (`setHook`), `HasPriceFeed.sol:27` (`setPriceFeed`)

Owner can instantly change tier prices, hooks, price feed, renderer, and discount parameters. Active subscribers have no time to react.

**Recommendation**: Use a timelock for critical changes, or at minimum a multisig as owner.

### [M-8] Compromised Owner Key Can Drain All Funds
**Sources**: AC-3
**Location**: `Support.sol:239` (`withdraw`), `Support.sol:233` (`setHook`)

A compromised owner can drain ETH, set a malicious hook to brick subscriptions, and point to a malicious oracle. No multisig requirement or timelock.

**Recommendation**: Use a multisig (Gnosis Safe) as owner. Document as deployment requirement.

### [M-9] Subscription Orphaning on Token Transfer
**Sources**: G-9
**Location**: `WithSupportTokens.sol:76`

`subscription[to] = tokenId` unconditionally overwrites the recipient's subscription mapping. If the recipient had an expired subscription pointing to a different token, the old subscription data becomes orphaned in storage.

**Recommendation**: Verify recipient's existing subscription state before overwriting, or document as acceptable.

### [M-10] ETH Refund Blocked by Reverting Receiver
**Sources**: DOS-5, NFT-6
**Location**: `Support.sol:154-158`

If `msg.sender` is a contract without `receive()` and overpays, the refund fails and the entire `support()` transaction reverts. Affects multisigs, DAOs, and batching contracts.

**Recommendation**: Use pull-payment pattern for refunds, or accept exact-payment-only from contracts.

---

## Low Severity

### [L-1] `addTier()` uint8 Overflow at 256+ Tiers
**Sources**: G-3, PM-5
**Location**: `Support.sol:229`

`uint8(tierPrices.length - 1)` silently wraps at 256+ tiers. Tiers beyond index 255 are unreachable since `tier` parameter is `uint8`.

**Recommendation**: Add `if (tierPrices.length >= type(uint8).max) revert InvalidTier()`.

### [L-2] Force-Feed Balance Inflation via `selfdestruct`
**Sources**: G-2
**Location**: `Support.sol:239-245`

ETH can be force-fed via `selfdestruct`, inflating `address(this).balance`. Benign (benefits owner) but breaks any future balance-based invariants.

### [L-3] `_mint` Used Instead of `_safeMint`
**Sources**: NFT-1
**Location**: `WithSupportTokens.sol:92`

Tokens minted to non-receiver contracts are permanently stuck. Trade-off: `_safeMint` introduces reentrancy vector.

### [L-4] Future `startAt` in `grant()` Causes Renderer Underflow
**Sources**: G-12, G-13, NFT-11
**Location**: `Support.sol:170`, `SupportRenderer.sol:54`

`grant()` allows future `startAt`. The renderer's `block.timestamp - data.startedAt` underflows, reverting `tokenURI()` until the start time passes.

**Recommendation**: Validate `startAt <= block.timestamp` in `grant()`, or guard in renderer.

### [L-5] DiscountHook Allows 100% Discount (Free Subscriptions)
**Sources**: G-11, PM-3
**Location**: `DiscountHook.sol:47-52`

`percentOff = 100` is allowed, making subscriptions free. Combined with `minMonths = 0`, all subscriptions become free.

### [L-6] Hardcoded 8-Decimal Assumption for Price Feed
**Sources**: O-4, PM-2
**Location**: `HasPriceFeed.sol:41`

`_usdToEth` assumes 8-decimal Chainlink feed. A feed with different decimals causes orders-of-magnitude pricing errors.

### [L-7] Missing `startedAt == 0` Validation on Chainlink Data
**Sources**: O-1
**Location**: `HasPriceFeed.sol:36-41`

### [L-8] No L2 Sequencer Uptime Check
**Sources**: O-3

### [L-9] Hardcoded 1-Hour Staleness Threshold
**Sources**: O-6
**Location**: `HasPriceFeed.sol:45-47`

Would cause constant reverts on L2s with 24-hour heartbeat feeds. `_maxStaleness()` is `virtual` (good), but not overridden.

### [L-10] Single Oracle Dependency with No Fallback
**Sources**: O-5

### [L-11] No Pause Mechanism
**Sources**: AC-2

### [L-12] DiscountHook/EvmNowSupporterHook Lack `onlySupport` on Callbacks
**Sources**: AC-4
**Location**: `DiscountHook.sol:44-45`

Currently no-ops, but inconsistent with MaxSlotsHook's `onlySupport` pattern.

### [L-13] Peripheral Contracts Use Single-Step `Ownable`
**Sources**: AC-5, AC-8
**Location**: `SupportRenderer.sol:12`, `DiscountHook.sol:9`

SupportRenderer and DiscountHook use `Ownable` (not `Ownable2Step`) and don't disable `renounceOwnership()`.

### [L-14] Third-Party Can Mint Unsolicited Subscription NFTs
**Sources**: AC-6
**Location**: `Support.sol:112`

Anyone can call `support(victimAddress, ...)` minting an NFT. Combined with OnePerWallet, this blocks the victim from receiving other tokens.

### [L-15] Transferred Token Retains Original History
**Sources**: NFT-5
**Location**: `WithSupportTokens.sol:66-87`

### [L-16] Returndata Bombing on ETH Refund and Hook Calls
**Sources**: G-6, DOS-6

### [L-17] `tierHistory` Array Grows Unboundedly
**Sources**: G-18, DOS-7, DOS-8
**Location**: `Support.sol:314-315`, `SupportRenderer.sol:116-124`

Each tier change appends to `tierHistory`. Large arrays make `tokenURI()` too gas-expensive. Self-limiting economically (tier changes cost ETH), and resets on reactivation.

---

## Informational (14)

| ID | Title | Sources |
|----|-------|---------|
| I-1 | PUSH0 opcode compatibility for non-mainnet chains | G-10 |
| I-2 | No `receive()`/`fallback()` -- positive security property | G-14 |
| I-3 | `_lastTier()` reverts on empty array (unreachable) | G-15 |
| I-4 | Hook call to address with no code | G-16 |
| I-5 | `_changeTier` rounding in cost supplement | G-17, PM-4 |
| I-6 | `baseUSD` multiplication safe within type bounds | PM-6 |
| I-7 | Renderer shows "0D" for sub-day periods | PM-8 |
| I-8 | No `unchecked` blocks (positive) | PM-9 |
| I-9 | Timestamp subtraction safe due to active-subscription guard | PM-10 |
| I-10 | 30-day month convention (360-day year) | PM-11 |
| I-11 | Latent reentrancy if switched to `_safeMint` | NFT-2 |
| I-12 | Constructor hardcodes `msg.sender` as owner in peripherals | AC-7 |
| I-13 | No deployment scripts in audit scope | AC-9 |
| I-14 | `withdraw()` only sends to `owner()` -- no configurable recipient | AC-11 |

---

## Cross-Cutting Concerns

### Hook Trust Model
The hook system is the largest attack surface. A single external contract (`hook`) is called in 3 places during `support()`, in `grant()`, and during NFT transfers. A reverting hook can DoS the entire protocol (H-2). The MaxSlotsHook's unbounded loops compound this (H-1). **Recommendation**: Define whether hooks are advisory or authoritative, wrap notification hooks in `try/catch`, and cap MaxSlotsHook array sizes.

### Oracle Dependency
The entire pricing mechanism depends on a single Chainlink feed with no fallback. Multiple findings (M-5, M-6, L-6, L-7, L-8, L-9, L-10) converge on oracle robustness. For a subscription protocol (not lending/DEX), the impact is limited to pricing errors and temporary DoS, not direct fund loss. `setPriceFeed()` provides an escape hatch.

### Centralization Risk
The owner has broad unilateral power: change prices, hooks, oracle, renderer; drain funds; grant free subscriptions. Multiple Medium findings (M-7, M-8) address this. **Recommendation**: Use a multisig as owner. Consider a timelock for parameter changes.

### ERC-721 Transfer Edge Cases
Token transfers interact with subscriptions, hooks, and OnePerWallet in subtle ways. Expired tokens block incoming transfers (M-4), subscription mappings can be orphaned (M-9), and hooks can freeze transfers (H-2). A `burn()` function for expired tokens would resolve several of these.

---

## What the Protocol Does Well

- **Checks-Effects-Interactions**: `support()` updates all state before the ETH refund
- **Ownable2Step**: Proper 2-step ownership on the core contract
- **renounceOwnership disabled**: Prevents accidental ownership loss
- **Oracle validation**: Checks `price <= 0`, `answeredInRound < roundId`, and timestamp staleness
- **Zero-price prevention**: Constructor and `setTierPrice` reject price = 0
- **No `unchecked` blocks**: All arithmetic has overflow protection
- **Virtual `_maxStaleness()`**: Allows per-chain override
- **`setPriceFeed()`**: Provides oracle migration escape hatch
- **Tier change authorization**: Only recipient or owner can change tiers

---

## Detailed Findings

For full details on each finding including proof-of-concept and code-level recommendations, see the individual findings files:

- [findings-general.md](findings-general.md) (18 findings)
- [findings-precision-math.md](findings-precision-math.md) (11 findings)
- [findings-erc721.md](findings-erc721.md) (11 findings)
- [findings-oracles.md](findings-oracles.md) (7 findings)
- [findings-access-control.md](findings-access-control.md) (11 findings)
- [findings-dos.md](findings-dos.md) (10 findings)
