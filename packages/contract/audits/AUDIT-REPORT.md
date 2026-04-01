# Security Audit Report: Support Protocol

**Date**: 2026-04-02
**Auditor**: Automated (6 parallel specialist agents)
**Scope**: `packages/contract/contracts/` (8 Solidity files)
**Checklists applied**: evm-audit-general, evm-audit-precision-math, evm-audit-oracles, evm-audit-access-control, evm-audit-dos, evm-audit-erc721

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 10 |
| Low | 11 |
| Info | 5 |
| **Total** | **28** |

The protocol is a tiered subscription system (4 tiers) paid in ETH via Chainlink price feed, with subscriptions represented as ERC-721 tokens. The two highest-risk areas are: **(1) the hook trust boundary** -- a reverting hook permanently DoS-es all subscriptions AND token transfers, and **(2) unbounded loops in MaxSlotsHook** -- large `maxSlots` values can exceed the block gas limit. Both are High severity.

---

## High Severity

### [H-1] Reverting hook permanently blocks all subscriptions and token transfers

**Severity**: High
**Categories**: evm-audit-access-control, evm-audit-dos, evm-audit-erc721
**Locations**:
- `Support._notifyHook()` — `Support.sol:273-279`
- `Support._beforeSubscribe()` — `Support.sol:356-364`
- `WithSupportTokens._update()` — `WithSupportTokens.sol:88-95`

**Description**: The hook contract is called without `try/catch` during three critical paths: `support()`, `grant()`, and ERC-721 transfers. If the hook's `onSubscribe()`, `onRelease()`, or `beforeSubscribe()` reverts — whether due to a bug, gas exhaustion, or malicious logic — the entire transaction reverts. This means:
- All paid subscriptions are blocked
- All owner grants are blocked
- All transfers of active tokens are frozen (NFTs become non-transferable)

The only recovery is `owner.setHook(address(0))`, but during the window between hook failure and owner intervention, the protocol is fully bricked.

**Proof of Concept**:
1. Owner sets a hook whose `onSubscribe()` always reverts (or has a latent bug triggered by edge-case inputs).
2. All `support()`, `grant()`, and `transferFrom()` calls revert.
3. Users cannot subscribe, extend, change tiers, or transfer tokens until the owner notices and removes the hook.

**Recommendation**: Wrap hook notification calls in `try/catch`. Keep `beforeSubscribe` as a hard revert (it controls pricing) but make `onSubscribe`/`onRelease` best-effort:
```solidity
function _notifyHook(ISubscriptionHook h, uint8 previousTier, uint8 tier, address recipient) internal {
    if (address(h) == address(0)) return;
    if (previousTier != type(uint8).max && previousTier != tier) {
        try h.onRelease(previousTier, recipient) {} catch {}
    }
    try h.onSubscribe(tier, recipient) {} catch {}
}
```
Apply the same pattern in `WithSupportTokens._update()`.

*Deduplicated from: AC-1, DOS-4, G-7, DOS-9, NFT-7*

---

### [H-2] Unbounded loops in MaxSlotsHook exceed block gas limit for large slot counts

**Severity**: High
**Categories**: evm-audit-dos, evm-audit-general
**Locations**:
- `MaxSlotsHook.onSubscribe()` — `MaxSlotsHook.sol:65-72`
- `MaxSlotsHook._canSubscribe()` — `MaxSlotsHook.sol:130-134`
- `MaxSlotsHook.activeTierHolders()` — `MaxSlotsHook.sol:109-121`

**Description**: When all tier slots are occupied, both `_canSubscribe()` and `onSubscribe()` iterate the entire `_tierHolders` array. Each iteration calls `_isActiveOnTier()`, which makes **2 cross-contract calls** to the Support contract (`activeTokenOf` + `currentTier`). Since both loops run per subscription (`_canSubscribe` in `beforeSubscribe` + `onSubscribe`), a single `support()` call triggers up to `2 * maxSlots * 2 = 4 * maxSlots` external calls. With `maxSlots` as a `uint16` (max 65,535), even modest values (500+) can exceed the block gas limit.

Additionally, `activeTokenOf()` in `WithSupportTokens` itself contains an unbounded loop over the user's token balance — creating O(holders * tokens_per_holder) nested iteration.

**Proof of Concept**:
1. Owner sets `maxSlots[0] = 1000`.
2. 1000 subscribers fill all slots.
3. New subscriber triggers ~4000 external calls, exceeding the 30M gas block limit.
4. Tier 0 is permanently DoS-ed.

**Recommendation**: Cap `maxSlots` in `setMaxSlots()` (e.g., max 50-100), or replace the linear scan with O(1) tracking:
```solidity
function setMaxSlots(uint8 tier, uint16 max) external onlyOwner {
    if (tier >= 4) revert InvalidTier();
    if (max > 100) revert MaxSlotsTooHigh();
    maxSlots[tier] = max;
}
```

*Deduplicated from: DOS-1, DOS-2, G-2, DOS-11*

---

## Medium Severity

### [M-1] Hook can manipulate subscription pricing and duration without constraints

**Severity**: Medium
**Category**: evm-audit-access-control
**Location**: `Support._beforeSubscribe()` — `Support.sol:356-364`

**Description**: The hook's `beforeSubscribe()` returns `Adjustments` that fully control the final USD price, duration, and start time with no bounds checks. A malicious hook can set `adjustedUSD = 0` (free subscriptions), `adjustedDuration = 0` (pay for nothing), or `adjustedStart` to a past/future timestamp.

**Recommendation**: Add sanity bounds on hook return values in `_beforeSubscribe()`.

---

### [M-2] No timelock on critical parameter changes (hook, tier prices)

**Severity**: Medium
**Category**: evm-audit-access-control
**Location**: `Support.sol:219-229` (`setTierPrice`, `setHook`)

**Description**: The owner can instantly change tier prices (front-running user transactions) and swap the hook contract (bricking the protocol per H-1). No timelock or delay mechanism exists. Events are emitted but provide no advance warning.

**Recommendation**: Implement a 2-day timelock for `setHook()` and `setTierPrice()` changes.

---

### [M-3] Compromised owner key can drain funds and brick the protocol

**Severity**: Medium
**Category**: evm-audit-access-control
**Location**: `Support.sol:244` (`withdraw`), `Support.sol:226` (`setHook`), `Support.sol:219` (`setTierPrice`)

**Description**: A single compromised owner key can drain all ETH via `withdraw()`, set a malicious hook, set prices to `type(uint128).max`, and change the renderer — all instantly. `Ownable2Step` prevents accidental transfers but not key compromise.

**Recommendation**: Use a multisig (e.g., Gnosis Safe) as owner. Separate fund withdrawal authorization from parameter changes.

---

### [M-4] Oracle decimal precision hardcoded to 8 decimals without validation

**Severity**: Medium
**Categories**: evm-audit-precision-math, evm-audit-oracles
**Location**: `HasPriceFeed._usdToEth()` — `HasPriceFeed.sol:41`

**Description**: The formula `usdAmount * 1e18 / uint256(price)` assumes the Chainlink feed returns 8 decimals. The `AggregatorV3Interface` in the dependency doesn't even expose a `decimals()` function. If the feed is changed to one with different decimal precision, conversions are off by orders of magnitude.

**Proof of Concept**: Switching to an 18-decimal feed would make users pay 10 billion times less than intended.

**Recommendation**: Validate `priceFeed.decimals() == 8` in the constructor or `setPriceFeed()`, or normalize dynamically.

*Deduplicated from: PM-4, O-3*

---

### [M-5] No Chainlink circuit breaker (minAnswer/maxAnswer) check

**Severity**: Medium
**Category**: evm-audit-oracles
**Location**: `HasPriceFeed._usdToEth()` — `HasPriceFeed.sol:35-42`

**Description**: Chainlink feeds have hard-coded `minAnswer`/`maxAnswer` bounds. When ETH crashes below `minAnswer`, the feed reports `minAnswer` instead of the real price. The contract would undercharge users, and the owner receives less ETH value than expected.

**Recommendation**: Query the aggregator's bounds and validate the price is not pinned at a circuit breaker boundary.

---

### [M-6] L2 deployment risks: staleness threshold, sequencer uptime, cheap slot-filling

**Severity**: Medium
**Categories**: evm-audit-oracles, evm-audit-dos
**Locations**:
- `HasPriceFeed._maxStaleness()` — `HasPriceFeed.sol:45-47`
- `MaxSlotsHook._tierHolders` — `MaxSlotsHook.sol:25`

**Description**: Three issues compound on L2 deployments:
1. **Staleness**: The hardcoded 1-hour staleness threshold is incompatible with L2 feeds (24-hour heartbeat on Arbitrum/Base). Every `_usdToEth()` call would revert with `StalePrice` for 23 of every 24 hours.
2. **Sequencer uptime**: No check for L2 sequencer downtime, allowing stale prices after sequencer restart.
3. **Cheap slot-filling**: Low L2 gas costs make it economically trivial to fill MaxSlotsHook arrays with sybil addresses (especially on free tiers), triggering the DoS in H-2.

**Recommendation**: Override `_maxStaleness()` per chain, add a sequencer uptime oracle for L2, and enforce minimum subscription costs when using MaxSlotsHook.

*Deduplicated from: O-4, O-5, DOS-10*

---

### [M-7] Division-before-multiplication in tier upgrade cost calculation

**Severity**: Medium
**Category**: evm-audit-precision-math
**Location**: `Support._changeTier()` — `Support.sol:289-291`

**Description**: The pro-rated cost is calculated as:
```solidity
uint256 diffUSD = uint256(newPrice - oldPrice) * remaining / 30 days;
required = _usdToEth(diffUSD + adj.adjustedUSD);
```
The division by `30 days` truncates `diffUSD` before `_usdToEth()` multiplies by `1e18`. This is a classic division-before-multiplication precision loss. While each individual loss is small (~100 wei), it compounds across many tier changes.

**Recommendation**: Defer the division: compute `numerator * 1e18 / (30 days * price)` in a single expression.

---

### [M-8] Downgrading to a free tier ($0 price) does not convert remaining value

**Severity**: Medium
**Category**: evm-audit-general
**Location**: `Support._changeTier()` — `Support.sol:297-301`

**Description**: When `tierPrices[toTier] == 0`, the downgrade formula sets `converted = remaining` (same number of seconds). A user with 15 days on a $50/mo tier who downgrades to a $0 tier gets only 15 days instead of infinite/capped time. The ~$25 prepaid value is effectively lost.

**Recommendation**: Cap `converted` at `type(uint64).max` when `newPrice == 0`, or document this as intended behavior.

---

### [M-9] Unbounded token-balance loops in WithSupportTokens

**Severity**: Medium
**Categories**: evm-audit-dos, evm-audit-erc721
**Locations**:
- `WithSupportTokens._transferActiveToken()` — `WithSupportTokens.sol:108`
- `WithSupportTokens._receiveActiveToken()` — `WithSupportTokens.sol:128`
- `WithSupportTokens._activeTokenOf()` — `WithSupportTokens.sol:155`
- `WithSupportTokens._hasActiveTierToken()` — `WithSupportTokens.sol:167`

**Description**: Four functions iterate over a user's entire ERC-721 balance. Tokens are never burned, so balances only grow. An address with many expired tokens faces increasingly expensive subscription and transfer operations. Combined with MaxSlotsHook's per-holder calls, this creates O(holders * tokens_per_holder) nested iteration.

**Recommendation**: Maintain the `activeToken` mapping eagerly rather than lazily scanning. Consider adding a `burn()` function for expired tokens.

*Deduplicated from: G-14, DOS-7, NFT-5, DOS-11*

---

### [M-10] `_mint` used instead of `_safeMint` — tokens locked in non-receiver contracts

**Severity**: Medium
**Category**: evm-audit-erc721
**Location**: `WithSupportTokens._onNewSubscription()` — `WithSupportTokens.sol:141`

**Description**: `_mint` is used instead of `_safeMint`, so no `onERC721Received` check occurs. When a third party calls `support(contractAddress, ...)` for a contract that doesn't implement `IERC721Receiver`, the token is permanently locked. Since third-party subscriptions are a documented feature, this is a realistic scenario (e.g., subscribing a multisig or governance contract).

**Recommendation**: Use `_safeMint` with a reentrancy guard, or document that `_mint` is intentional to avoid reentrancy.

*Deduplicated from: NFT-1, G-15*

---

### [M-11] TOCTOU gap between MaxSlotsHook `_canSubscribe` and `onSubscribe`

**Severity**: Medium  
**Category**: evm-audit-general  
**Location**: `MaxSlotsHook.sol:39-46` and `MaxSlotsHook.sol:52-75`

**Description**: `beforeSubscribe()` calls `_canSubscribe()` (view), then `_applySubscription()` modifies state, then `onSubscribe()` re-scans. The state changes between the two checks can cause divergent results — `_canSubscribe` may pass while `onSubscribe` reverts with `TierFull`, or vice versa.

**Recommendation**: Combine the check-and-assign into `onSubscribe()` alone, or accept the gap since both calls occur in the same transaction.

---

## Low Severity

### [L-1] No reentrancy guard on `support()` despite external calls

**Location**: `Support.sol:112-159`

The excess ETH refund hands control to `msg.sender` after state updates. While the checks-effects-interactions pattern is broadly followed, reentrant calls could interact poorly with hook state (e.g., MaxSlotsHook double-counting). Add `ReentrancyGuard.nonReentrant`.

*Deduplicated from: G-3, NFT-2*

---

### [L-2] Returndata bombing on excess refund and withdrawal calls

**Location**: `Support.sol:156` (refund), `Support.sol:247` (withdraw)

`.call{value}("")` does not cap return data. A malicious recipient can return megabytes, consuming gas quadratically. Use assembly `call()` with `(0, 0)` for returndatasize.

*Deduplicated from: G-1, DOS-6, DOS-8*

---

### [L-3] Hook contracts use single-step Ownable and don't disable renounceOwnership

**Location**: `MaxSlotsHook.sol:14`, `DiscountHook.sol:9`

Unlike `Support` (which uses `Ownable2Step` + blocked `renounceOwnership`), hooks use plain `Ownable`. A mistaken `transferOwnership` or `renounceOwnership` permanently locks hook admin functions.

*Deduplicated from: AC-5, AC-6*

---

### [L-4] DiscountHook lacks `onlySupport` modifier on `onSubscribe`/`onRelease`

**Location**: `DiscountHook.sol:40-41`

Currently no-ops, but the missing access control is inconsistent with `MaxSlotsHook` and could become dangerous if state-modifying logic is added later.

*Deduplicated from: G-12, AC-7*

---

### [L-5] `percentOff = 100` allowed, making all qualifying subscriptions free

**Location**: `DiscountHook.sol:18-21`, `DiscountHook.sol:43-48`

The validation `_percentOff > 100` should be `>= 100` unless 100% discounts are intended. Combined with rounding, even high discounts with small prices can round `adjustedUSD` to zero.

*Deduplicated from: G-13, PM-3*

---

### [L-6] Tier upgrade pro-rata and downgrade conversion have inconsistent rounding directions

**Locations**: `Support.sol:289` (upgrade — rounds down, favors user), `Support.sol:299` (downgrade — rounds down, favors protocol)

Both divisions truncate, but the beneficiary differs. Adopt a consistent "round in protocol's favor" policy.

*Deduplicated from: PM-1, PM-2, G-11*

---

### [L-7] Tier change with very small remaining time rounds pro-rated cost to zero

**Location**: `Support._changeTier()` — `Support.sol:289`

When `(newPrice - oldPrice) * remaining < 30 days`, `diffUSD` rounds to zero. With realistic tier prices (8-decimal USD), this only triggers with <6 seconds remaining.

---

### [L-8] Tier change to same-priced tiers follows downgrade path

**Location**: `Support._changeTier()` — `Support.sol:289-301`

Equal-price tier changes follow the downgrade path, which preserves remaining time AND charges for additional months. The upgrade path would charge only the differential. This inconsistency could be confusing.

---

### [L-9] Single oracle dependency with no fallback

**Location**: `HasPriceFeed.sol:35-42`

If the Chainlink feed reverts (deprecated, access revoked), all paid subscriptions are bricked. The owner can recover via `setPriceFeed()`, but there's no graceful degradation. `grant()` still works.

*Deduplicated from: O-6, O-7*

---

### [L-10] Missing `startedAt == 0` validation on oracle round data

**Location**: `HasPriceFeed._usdToEth()` — `HasPriceFeed.sol:36`

The `startedAt` return value is discarded. A round with `startedAt == 0` is uninitialized and should be rejected.

---

### [L-11] PUSH0 opcode incompatibility with some L2s

**Location**: All contracts — `pragma solidity ^0.8.28`

Solidity >= 0.8.20 emits `PUSH0`, which some chains don't support. Set `evmVersion: "paris"` if targeting incompatible chains.

---

## Informational

### [I-1] `withdraw()` includes force-fed ETH in balance

**Location**: `Support.sol:244-250`. The `Withdrawal` event may not match the sum of subscription payments. Track collected payments explicitly if accurate accounting matters.

### [I-2] 30-day month approximation causes ~5 day/year drift

**Location**: `Support.sol:337`. A 12-month subscription lasts 360 days, not 365. Internally consistent but should be documented.

### [I-3] Third parties can extend subscriptions, preventing natural expiry

**Location**: `Support.sol:112`. Documented behavior, but users have no opt-out mechanism.

### [I-4] Tokens are never burned — permanent state growth

**Location**: `WithSupportTokens.sol`. `totalSupply()` only increases. Consider adding an optional burn for expired tokens.

### [I-5] `_update` hook notification has asymmetric tier tracking

**Location**: `WithSupportTokens.sol:90-95`. `onSubscribe` always fires for the receiver (even if they already hold a same-tier token), while `onRelease` correctly only fires when the sender has no remaining tokens. Hook implementations must be idempotent.

---

## Architecture Notes

**Positive patterns observed:**
- `Ownable2Step` with disabled `renounceOwnership` on the main contract
- Explicit `afterSaleStart` modifier
- Consistent 30-day month throughout pricing and duration
- The `ReentrancyAttacker` mock shows the team actively considered reentrancy risks
- `uint64` overflow-safe capping in `_addDuration` and `_changeTier`

**Key risk areas:**
1. **Hook trust boundary** is the largest systemic risk — the hook has unconstrained influence over pricing AND its revert behavior bricks the entire protocol including token transfers.
2. **MaxSlotsHook scalability** — the O(n) scan with cross-contract calls is the primary DoS vector.
3. **Oracle dependency** — the external `HasPriceFeed` library lacks modern Chainlink best practices (decimal validation, circuit breakers, L2 sequencer checks).

---

## Individual Finding Files

Detailed findings with full PoCs are in:
- `findings-general.md` (15 findings)
- `findings-precision-math.md` (7 findings)
- `findings-oracles.md` (8 findings)
- `findings-access-control.md` (8 findings)
- `findings-dos.md` (11 findings)
- `findings-erc721.md` (10 findings)
