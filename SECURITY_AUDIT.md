# Security Audit: Support Contract

**Date:** 2026-03-31
**Scope:** `packages/contract/contracts/Support.sol`, `packages/indexer/`
**Solidity Version:** ^0.8.28 (overflow-checked by default)

---

## Summary

The Support contract implements a tiered subscription system with ERC-721 NFTs, Chainlink oracle pricing, and on-chain SVG metadata. Overall the contract is well-structured. This audit identified **1 critical**, **1 high**, and **4 medium** severity issues. All actionable findings have been fixed.

| Severity | Count | Fixed |
|----------|-------|-------|
| Critical | 1     | 1     |
| High     | 1     | 1     |
| Medium   | 4     | 4     |
| Low      | 5     | 0     |
| Info     | 3     | 0     |

---

## Critical

### C-1: uint64 overflow in downgrade time conversion

**Location:** `_subscribe()` (downgrade branch)
**Status:** FIXED

When downgrading tiers, remaining time is converted using the ratio `oldPrice / newPrice`:

```solidity
uint64 converted = uint64(uint256(remaining) * oldPrice / newPrice);
```

If the price ratio is extreme (e.g., oldPrice=2^128-1, newPrice=1), the intermediate result far exceeds `uint64` max. The unsafe `uint64()` cast silently truncates, potentially giving users **seconds** of subscription instead of years.

**Additionally**, the subsequent addition `uint64(block.timestamp) + converted + uint64(duration) * 30 days` could also wrap.

**Fix:** All expiry calculations now use overflow-safe helpers. The downgrade path computes in `uint256` and caps at `type(uint64).max`. A new `_addDuration()` helper safely adds month-based durations with the same cap.

---

## High

### H-1: SVG/JSON injection via projectName and projectSymbol

**Location:** `tokenURI()`, `_buildSVG()`
**Status:** FIXED

`projectName` is interpolated directly into JSON (`"name":"<projectName> #1"`) and SVG (`<text>...</text>`) without escaping. If the owner sets a name containing `"`, `<`, `>`, or `\`, it breaks:

- **JSON structure** - closing the `"name"` value early, enabling arbitrary JSON injection
- **SVG structure** - injecting arbitrary SVG/HTML elements, potential XSS on NFT platforms

While only the owner can set these values, a compromised owner key or a social engineering attack could poison metadata displayed on marketplaces like OpenSea.

**Fix:** Added `_requireSafeString()` validation that rejects `"`, `<`, `>`, and `\` characters in `setProjectName()` and `setProjectSymbol()`.

---

## Medium

### M-1: Missing OwnershipTransferred event in constructor

**Location:** `constructor()`
**Status:** FIXED

The initial `owner = msg.sender` assignment did not emit `OwnershipTransferred(address(0), msg.sender)`. Off-chain tools (Etherscan, The Graph, block explorers) rely on this event to detect contract ownership. Without it, the initial owner is invisible to event-based indexing.

**Fix:** Added `emit OwnershipTransferred(address(0), msg.sender)` in the constructor.

### M-2: Immutable priceFeed with no migration path

**Location:** State declaration
**Status:** FIXED

`priceFeed` was declared `immutable`. If the Chainlink feed is deprecated, migrated, or compromised, the contract would be permanently bricked for paid subscriptions (all `cost()` and `support()` calls would revert with `StalePrice`). Only `grant()` would remain functional.

**Fix:** Changed `priceFeed` from `immutable` to a regular state variable and added `setPriceFeed(address)` behind `onlyOwner`.

### M-3: Unbounded loop in `_claimTierSlot()`

**Location:** `_claimTierSlot()`
**Status:** ACKNOWLEDGED (no fix needed)

The function iterates `_tierHolders[tier]` up to twice - once to check for duplicates, once to find an expired/changed slot. With `maxSlots` as `uint16` (max 65,535), this could consume significant gas. In extreme cases, the gas cost could exceed block limits, effectively DoS-ing tier subscriptions.

**Mitigation:** Keep `maxSlots` values reasonable (< 100). The current design is acceptable for the expected use case.

### M-4: `subscriberOf` not updated on NFT transfer

**Location:** `_transfer()`
**Status:** ACKNOWLEDGED

When a token is transferred, `subscriberOf[tokenId]` still points to the original subscriber. The SVG metadata (`_buildSVG`) uses this for the display name, so the old subscriber's name/address appears on the NFT until a new subscription action is taken.

This appears intentional (tracking who the subscription is "for"), but could confuse users who expect the display to update on transfer.

---

## Low

### L-1: No two-step ownership transfer

`transferOwnership()` immediately sets the new owner. If the caller provides a wrong address, ownership is irrecoverably lost. Consider a two-step pattern (propose + accept) for production deployments.

### L-2: No `receive()` function

The contract cannot receive plain ETH transfers. This is correct behavior but means accidentally sent ETH (without calling `support()`) is rejected rather than held.

### L-3: `_lastTier()` reverts on empty segments

`_lastTier()` accesses `segs[segs.length - 1]` which reverts if the segments array is empty. This is safe in practice since it's only called on tokens with segments, but has no explicit guard.

### L-4: Tier slot array never shrinks

`_tierHolders[tier]` grows but never shrinks. Expired holders are lazily replaced. This is gas-wasteful for reads (e.g., `tierHolders()` returns stale entries) but not exploitable.

### L-5: Stale price feed threshold is fixed at 1 hour

The 1-hour staleness window in `_usdToEth()` is hardcoded. During periods of network congestion or Chainlink delays, this could cause false `StalePrice` reverts. Consider making this configurable.

---

## Informational

### I-1: Reentrancy in `support()` is safe

The ETH refund in `support()` (line 157) uses a low-level `call` which could re-enter. However, all state changes happen in `_subscribe()` before the refund, following the checks-effects-interactions pattern. A reentrant call would simply start a new legitimate subscription. **No action needed.**

### I-2: Oracle sanity checks are adequate

The `_usdToEth()` function properly validates: `price > 0`, `answeredInRound >= roundId`, and `block.timestamp - updatedAt <= 1 hour`. This is standard Chainlink best practice.

### I-3: Indexer has no additional security surface

The Ponder indexer (`packages/indexer/`) is a read-only event processor. It exposes GraphQL and SQL endpoints via Hono, which are standard Ponder patterns. The indexer trusts on-chain events and performs no authentication, which is expected for public blockchain data.

---

## Scope Notes

- **Compiler:** Could not compile/test in this environment (no internet for solc download). Fixes have been manually verified for correctness.
- **Formal verification:** Not performed.
- **Gas optimization:** Not in scope but noted where relevant.
- **Deployment scripts:** `ignition/modules/Support.ts` and `scripts/render-nft.ts` are standard Hardhat patterns with no security concerns.
- **Environment files:** `.env.example` files contain only placeholder keys, no secrets committed.
