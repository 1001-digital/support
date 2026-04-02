# Precision & Math Audit Findings

**Auditor**: Claude Opus 4.6 (1M context)
**Date**: 2026-04-02
**Scope**: All contracts in `packages/contract/contracts/` (excluding mocks)
**Checklist**: `evm-audit-precision-math`

---

## [PM-1] Division before multiplication in `_changeTier()` time-remaining conversion

**Severity**: Medium
**Category**: evm-audit-precision-math
**Location**: `_changeTier()` in `Support.sol:286`

**Description**: When a subscriber changes tiers, the remaining time on the old tier is converted to equivalent time on the new tier using:

```solidity
uint256 converted = uint256(remaining) * oldPrice / newPrice;
```

This is a single division that truncates. The truncation is proportional to `newPrice` and can cause meaningful loss of subscriber time. For example, if `remaining = 59 days`, `oldPrice = 5e8` (5 USD), and `newPrice = 10e8` (10 USD), the exact result is 29.5 days but the division truncates to 29 days, costing the subscriber 0.5 days. While a single division is not itself a division-before-multiplication bug, this truncated `converted` value is then **added** to other terms to form `rawExpiry`:

```solidity
uint256 rawExpiry = uint256(block.timestamp) + converted + uint256(adj.adjustedDuration) * 30 days;
```

The precision loss from the division of `remaining * oldPrice / newPrice` always rounds **against** the subscriber. With 8-decimal USD tier prices (Chainlink convention), a remainder of up to `newPrice - 1` ticks (~10 USD worth of seconds) is lost. For cheap tiers (e.g., 1 USD/month) this is negligible; for expensive tiers (e.g., 100 USD/month) the truncation cost rises.

**Proof of Concept**:
1. Subscriber has `remaining = 1 second` on a tier priced at `1e8` (1 USD).
2. They upgrade to a tier priced at `3e8` (3 USD).
3. `converted = 1 * 1e8 / 3e8 = 0` -- the subscriber loses their entire remaining 1 second.
4. More realistically: `remaining = 86399` (just under 1 day), `oldPrice = 5e8`, `newPrice = 12e8`: `converted = 86399 * 5e8 / 12e8 = 35999` (0.41 days), losing about 0.007 days. Losses compound with larger price ratios.

**Recommendation**: This is an inherent property of integer division and the loss magnitude is small for realistic tier prices. To mitigate, consider rounding up in favor of the subscriber for the time conversion:

```solidity
uint256 converted = (uint256(remaining) * oldPrice + newPrice - 1) / newPrice;
```

Alternatively, document that tier changes truncate fractional time against the subscriber as intended behavior.

---

## [PM-2] USD-to-ETH conversion assumes 8-decimal Chainlink feed without verification

**Severity**: Low
**Category**: evm-audit-precision-math
**Location**: `_usdToEth()` in `HasPriceFeed.sol:41`, consumed by `_baseCost()` in `Support.sol:348`

**Description**: The `_usdToEth` function computes:

```solidity
return usdAmount * 1e18 / uint256(price);
```

This assumes the Chainlink price feed returns prices with 8 decimals (the standard for ETH/USD). The function never calls `priceFeed.decimals()` to verify. If the owner sets a price feed with a different decimal precision (e.g., 18 decimals for a custom feed, or 6 decimals for some other oracle), the conversion will be wrong by orders of magnitude.

The `tierPrices` are `uint128` values that the comment says use "the same decimal precision as the price feed (8 decimals for Chainlink ETH/USD)." If tier prices are set assuming 8 decimals (e.g., `5e8` for $5) but the feed returns 18-decimal prices, `usdAmount * 1e18 / price` would produce a value ~1e10x too small, making subscriptions essentially free. Conversely, a 6-decimal feed would make subscriptions ~100x too expensive.

**Proof of Concept**:
1. Owner deploys with a custom price feed that returns 18-decimal prices (e.g., `3000e18` for $3000 ETH).
2. Tier price is `5e8` (intended as $5 at 8-decimal precision).
3. `_usdToEth(5e8) = 5e8 * 1e18 / 3000e18 = 5e8 / 3000 = 166666` wei (~0.000000000000166 ETH).
4. Subscription costs virtually nothing.

**Recommendation**: Either hardcode the assumption with a deploy-time check:

```solidity
require(priceFeed.decimals() == 8, "Feed must be 8 decimals");
```

Or normalize dynamically:

```solidity
uint8 dec = priceFeed.decimals();
return usdAmount * 1e18 / (uint256(price) * 10**(18 - dec));
```

---

## [PM-3] Discount calculation rounds against protocol, allowing 100% discount to zero out cost

**Severity**: Low
**Category**: evm-audit-precision-math
**Location**: `_applyDiscount()` in `DiscountHook.sol:34`

**Description**: The discount formula is:

```solidity
adj.adjustedUSD = baseUSD * (100 - percentOff) / 100;
```

When `percentOff == 100`, this evaluates to `baseUSD * 0 / 100 = 0`, making the subscription free. The constructor allows `_percentOff == 100` (`if (_percentOff > 100) revert`), so the owner can configure a 100% discount that eliminates all payment requirements.

Additionally, this division rounds **down** (toward zero), meaning the protocol always receives slightly less than the exact discounted amount. For example, `baseUSD = 999` and `percentOff = 10` gives `999 * 90 / 100 = 899` instead of the exact 899.1. The rounding direction favors subscribers over the protocol on every transaction. Over many transactions this leaks small amounts of value.

**Proof of Concept**:
1. Owner calls `setDiscount(1, 100)` -- 100% off for subscriptions >= 1 month.
2. Any subscriber calls `support()` with `msg.value = 0` and gets a full subscription for free.
3. For the rounding case: with tier price `3333333` (8 decimals) and 20% off for 1 month: `3333333 * 80 / 100 = 2666666` instead of exact `2666666.4`. Protocol loses 0.4 units (~$0.000000004).

**Recommendation**: If 100% discounts are not intended, change the guard to `if (_percentOff >= 100) revert InvalidDiscount()`. For the rounding direction, consider rounding up: `(baseUSD * (100 - percentOff) + 99) / 100`. The practical impact of the rounding is negligible given USD-level tier prices.

---

## [PM-4] `_changeTier()` minimum-expiry top-up has division before multiplication

**Severity**: Low
**Category**: evm-audit-precision-math
**Location**: `_changeTier()` in `Support.sol:293`

**Description**: When upgrading to a more expensive tier, if the converted remaining time is less than 30 days, the contract charges extra to reach the 30-day minimum:

```solidity
required += _baseCost(uint256(newPrice) * (minExpiry - rawExpiry) / 30 days);
```

This expression first computes `uint256(newPrice) * (minExpiry - rawExpiry)` then divides by `30 days`. This is correct ordering (multiply before divide). However, the division by `30 days` (2592000 seconds) truncates. The truncated value is then passed to `_baseCost()` which calls `_usdToEth()` which does another division: `usdAmount * 1e18 / uint256(price)`.

This creates a chain of two sequential divisions, each losing precision. The first division can lose up to `30 days - 1` ticks of `newPrice` (equivalent to a few cents of USD). The second division (in `_usdToEth`) can lose up to `price - 1` ticks (negligible at 8-decimal ETH prices worth ~$3000).

**Proof of Concept**:
1. `newPrice = 10e8`, `minExpiry - rawExpiry = 2591999` (just under 30 days, i.e., 29.999... days).
2. `uint256(10e8) * 2591999 / 2592000 = 9999996` (loses ~4 out of 10e8).
3. This then goes through `_usdToEth(9999996)` where the final division truncates again.
4. Net effect: protocol receives about $0.00000004 less than exact proportional charge. This is negligible.

**Recommendation**: The precision loss here is extremely small in practice. No fix is strictly necessary. For maximum precision, the two divisions could be combined:

```solidity
required += uint256(newPrice) * (minExpiry - rawExpiry) * 1e18 / (30 days * uint256(price));
```

But this changes the interface (bypassing `_baseCost`) and the savings are sub-cent.

---

## [PM-5] `addTier()` downcast of `tierPrices.length` to `uint8` can silently overflow

**Severity**: Low
**Category**: evm-audit-precision-math
**Location**: `addTier()` in `Support.sol:229`

**Description**: After pushing a new tier price, the code emits:

```solidity
emit TierPriceUpdated(uint8(tierPrices.length - 1), priceUSD);
```

If the owner manages to add more than 256 tiers, `uint8(tierPrices.length - 1)` will silently truncate, emitting an incorrect tier index in the event. The `tier` parameter throughout the system is typed as `uint8`, meaning the contract logically supports at most 256 tiers. However, `tierPrices` is a `uint128[]` which can hold more than 256 entries. If `tierPrices.length > 256`, the `tier >= tierPrices.length` guards in `support()` and `grant()` would still pass for `tier` values 0-255, but tiers 256+ would be unreachable since `uint8` cannot represent them.

**Proof of Concept**:
1. Owner calls `addTier()` 257 times.
2. The 257th call pushes index 256. `uint8(256) == 0`, so the event `TierPriceUpdated(0, ...)` is emitted, falsely suggesting tier 0's price was updated.
3. Tier index 256 exists in the array but is unreachable through any function that takes `uint8 tier`.

**Recommendation**: Add a guard in `addTier()`:

```solidity
if (tierPrices.length >= type(uint8).max) revert InvalidTier();
```

This caps the array at 255 tiers (indices 0-254), which is more than sufficient. Alternatively, use `SafeCast.toUint8()`.

---

## [PM-6] `_beforeSubscribe` baseUSD multiplication can overflow for extreme inputs

**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: `_beforeSubscribe()` in `Support.sol:341`

**Description**: The base USD cost is computed as:

```solidity
uint256 baseUSD = uint256(tierPrices[tier]) * duration;
```

`tierPrices[tier]` is `uint128` (max ~3.4e38) and `duration` is `uint32` (max ~4.29e9). The product can reach ~1.46e48, which is well within `uint256` range (max ~1.15e77). There is no overflow risk here.

However, it is worth noting that a `uint128` tier price of `type(uint128).max` would represent an absurdly large USD amount (~$3.4e30 at 8 decimals), far beyond any realistic use. The owner controls tier prices, so this is not exploitable by third parties.

**Proof of Concept**: Not exploitable. `uint128.max * uint32.max = ~1.46e48 < uint256.max`. No overflow occurs.

**Recommendation**: No action required. The math is safe within the constraints of the types used.

---

## [PM-7] `_usdToEth` can return zero for small USD amounts, enabling free subscriptions via rounding

**Severity**: Medium
**Category**: evm-audit-precision-math
**Location**: `_usdToEth()` in `HasPriceFeed.sol:41`, called from `_baseCost()` in `Support.sol:348`

**Description**: The USD-to-ETH conversion computes:

```solidity
return usdAmount * 1e18 / uint256(price);
```

If `usdAmount * 1e18 < price`, this expression returns 0. With an ETH price of $3000 (Chainlink returns `3000e8 = 3e11`), any `usdAmount` where `usdAmount * 1e18 < 3e11` rounds to zero. That means `usdAmount < 3e11 / 1e18 = 0.0000003`, i.e., `usdAmount < 1` in 8-decimal terms.

In practice, tier prices are set in 8-decimal format (e.g., `5e8` for $5), so the smallest realistic `usdAmount` passed to `_usdToEth` after discount would be `1` (representing $0.00000001). For this edge case: `1 * 1e18 / 3e11 = 3333333` wei (~$0.00000001), which is non-zero. So for Chainlink ETH/USD feeds with 8-decimal prices, this returns 0 only for `usdAmount == 0`, which is already handled by `_baseCost`:

```solidity
if (adjustedUSD == 0) return 0;
```

However, the risk becomes relevant if a hook returns a very small but non-zero `adjustedUSD`. The `_baseCost` check passes (non-zero), but `_usdToEth` could return 0 if the price feed uses higher precision or the ETH price is extremely high. In that scenario, the subscriber pays 0 ETH for a non-free subscription.

**Proof of Concept**:
1. Hypothetical: ETH at $1,000,000 (price feed returns `1e14`).
2. Hook returns `adjustedUSD = 1` (smallest non-zero).
3. `_usdToEth(1) = 1 * 1e18 / 1e14 = 10000` wei = 0.00000000000001 ETH. This is non-zero but essentially free (~$0.00000001).
4. The real concern is with non-standard feeds: if `price = 1e20`, then `usdAmount * 1e18` must exceed `1e20` to be non-zero, meaning `usdAmount > 100`.

**Recommendation**: Add a minimum ETH cost check after `_usdToEth`:

```solidity
function _baseCost(uint256 adjustedUSD) internal view returns (uint256) {
    if (adjustedUSD == 0) return 0;
    uint256 cost = _usdToEth(adjustedUSD);
    require(cost > 0, "Cost rounds to zero");
    return cost;
}
```

Or, as a simpler approach, ensure all tier prices are large enough (e.g., at least `1e6` in 8-decimal terms = $0.01) that rounding to zero is impossible at any realistic ETH price.

---

## [PM-8] Renderer division by `1 days` can produce zero for sub-day subscription periods

**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: `_buildSVG()` in `SupportRenderer.sol:56-57`, `_attributes()` in `SupportRenderer.sol:123`

**Description**: The SVG renderer computes durations using integer division by `1 days`:

```solidity
uint256 dur = data.active
    ? (block.timestamp - data.startedAt) / 1 days
    : (data.expiresAt - data.startedAt) / 1 days;
```

And in `_attributes()`:

```solidity
Strings.toString((segEnd - data.tierPeriods[i].startedAt) / 1 days)
```

If a subscription has been active for less than 24 hours, `dur` will be 0, and the SVG will display "0D". Similarly, tier periods shorter than 1 day display "0d". This is a cosmetic issue only -- it does not affect accounting or payments. The `dayNum` calculation on line 54 adds 1 to avoid showing "DAY 0":

```solidity
uint256 dayNum = (block.timestamp - data.startedAt) / 1 days + 1;
```

This means on the first day it shows "DAY 1", which is correct.

**Proof of Concept**: Subscribe, then view `tokenURI` within 24 hours. Duration shows "0D" in the SVG. No financial impact.

**Recommendation**: No action needed. This is purely cosmetic. If desired, display "< 1D" or use hours for short durations.

---

## [PM-9] No `unchecked` blocks with user-influenced values

**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: All contracts

**Description**: The codebase does not use any `unchecked` blocks. All arithmetic is protected by Solidity 0.8.28's built-in overflow/underflow checks. This is good practice and eliminates an entire class of precision/overflow bugs.

**Proof of Concept**: N/A -- no issue found.

**Recommendation**: No action required.

---

## [PM-10] Timestamp subtraction in `_changeTier()` is safe but undocumented

**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: `_changeTier()` in `Support.sol:280`

**Description**: The expression:

```solidity
uint64 remaining = currentExpiry - uint64(block.timestamp);
```

This subtraction is safe because `_changeTier()` is only called when the subscription is active (`active == true`), which means `currentExpiry > block.timestamp`. The `uint64(block.timestamp)` downcast is safe until the year 584,942,417,355 (when `block.timestamp` exceeds `type(uint64).max`).

However, `currentExpiry` is already `uint64`, and the subtraction produces a `uint64`. If `block.timestamp` were somehow larger than `currentExpiry` (which the active check prevents), this would revert due to Solidity 0.8 underflow protection. The code is correct.

**Proof of Concept**: N/A -- the active-subscription guard prevents underflow.

**Recommendation**: No action required. Optionally add a comment noting the active-subscription precondition.

---

## [PM-11] Duration uses 30-day months -- not a bug, but may surprise users

**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: `_addDuration()` in `Support.sol:325`, `_changeTier()` in `Support.sol:287`

**Description**: All duration calculations use `30 days` (2,592,000 seconds) as the month length:

```solidity
uint256 result = uint256(base) + uint256(duration) * 30 days;
```

This means a "12-month" subscription is 360 days, not 365. A subscriber paying for 12 months gets 5 fewer days than a calendar year. This is a common and reasonable simplification for on-chain subscription systems, but it should be documented clearly in user-facing materials.

**Proof of Concept**: Subscribe for 12 months. Subscription expires after 360 days, not 365.

**Recommendation**: Document in user-facing materials that 1 month = 30 days for all calculations. No code change needed.

---

# Checklist Items Reviewed with No Findings

The following checklist items were reviewed and found not applicable or not present in the codebase:

| Checklist Item | Result |
|---|---|
| Hidden division-before-multiplication in library calls | No chained `wmul`/`wdiv` patterns. The codebase uses plain arithmetic. |
| Extra divisions by scaling factor | No double-division by the same constant found. |
| Protocol-favoring rounding rule (ERC-4626 vaults) | Not applicable -- this is not a vault/share system. |
| Inconsistent rounding across functions | Not applicable -- no deposit/withdrawal share math. |
| Inverse fee calculation error | Not applicable -- no fee-adjusted share conversions. |
| Overflow in `unchecked` blocks | No `unchecked` blocks in the codebase. |
| Negative-to-unsigned cast | No signed-to-unsigned casts found. |
| Signed-unsigned addition/subtraction | No mixed signed/unsigned arithmetic found (price feed `int256` is checked `> 0` before cast). |
| Overflow in time-based calculations | `_addDuration` uses `uint256` intermediates and caps at `uint64.max`. Safe. |
| Token decimal mismatch in price calculations | Only one token type (ETH). No cross-token decimal issues. |
| Decimal scaling for vault with non-18 decimal assets | Not applicable -- no vault. |
| Compounding when claiming simple interest | Not applicable -- no interest/yield system. |
| Reward per token precision loss | Not applicable -- no staking rewards. |
| Missing state update before reward claim | Not applicable -- no reward mechanism. |
| Fee shares minted after reward distribution | Not applicable -- no share/fee mechanism. |
| Division by zero in assembly | No inline assembly used. |
| `type(uint256).max` as sentinel value | Not used in arithmetic. `type(uint8).max` is used as `NO_TIER` sentinel but only in comparisons. |
| Extreme weight ratios cause overflow | Not applicable -- no weighted pool math. |
| Solidity time literals are uint24 | Time literals are only used in expressions with `uint256` operands (e.g., `uint256(duration) * 30 days`), so the result is `uint256`. Safe. |
| Excessive precision scaling -- double-scaling | Not applicable -- single scaling path through `_usdToEth`. |
| Mismatched precision scaling -- decimals vs hardcoded | See PM-2 (oracle decimal assumption). |
| Downcast overflow silently invalidates pre-downcast invariant checks | See PM-5 (`addTier` uint8 cast). The `uint64(block.timestamp)` cast in PM-10 is safe for centuries. |
