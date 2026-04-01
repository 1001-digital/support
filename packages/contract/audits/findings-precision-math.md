# Precision & Math Audit Findings

Audited contracts:
- `packages/contract/contracts/Support.sol`
- `packages/contract/contracts/SupportToken.sol`
- `packages/contract/contracts/extensions/WithSupportTokens.sol`
- `packages/contract/contracts/hooks/MaxSlotsHook.sol`
- `packages/contract/contracts/hooks/DiscountHook.sol`
- `packages/contract/contracts/interfaces/ISubscriptionHook.sol`
- `packages/contract/contracts/interfaces/ISupportRenderer.sol`
- `packages/contract/contracts/renderers/SupportRenderer.sol`
- `node_modules/@1001-digital/erc721-extensions/contracts/HasPriceFeed.sol` (dependency)

Checklist: `evm-audit-precision-math`

---

## [PM-1] Tier upgrade pro-rata calculation rounds in favor of user, not protocol
**Severity**: Low
**Category**: evm-audit-precision-math
**Location**: `_changeTier()` in `Support.sol:289`
**Description**: When upgrading tiers, the pro-rated cost difference is calculated as:
```solidity
uint256 diffUSD = uint256(newPrice - oldPrice) * remaining / 30 days;
```
Solidity integer division truncates (rounds down), meaning the user pays slightly less than the exact pro-rated difference. The rounding should favor the protocol (round up), not the user. On each tier upgrade, up to `30 days - 1` seconds (2,591,999 wei-seconds) of price difference is lost to truncation.

For example, with a $15/month price difference and 15 days remaining:
- Exact: `1500000000 * 1296000 / 2592000 = 750000000` (no loss here)
- But with 15 days + 1 second remaining: `1500000000 * 1296001 / 2592000 = 750000000` (truncated, 1500000000 * 1 / 2592000 = 0 lost)

The loss is small per transaction but compounds across many upgrades.

**Proof of Concept**: A user with 1 second of remaining time on tier 0 ($5/mo) upgrades to tier 3 ($50/mo). `diffUSD = (5000000000 - 500000000) * 1 / 2592000 = 4500000000 / 2592000 = 1736` (8-decimal USD). The exact value should be `1736.11...`, so 0.11 units of 8-decimal USD is lost (~$0.0000011). Repeated across thousands of tier changes, this becomes meaningful.

**Recommendation**: Round up the division to favor the protocol:
```solidity
uint256 diffUSD = (uint256(newPrice - oldPrice) * remaining + 30 days - 1) / 30 days;
```

---

## [PM-2] Tier downgrade time conversion rounds in favor of user
**Severity**: Low
**Category**: evm-audit-precision-math
**Location**: `_changeTier()` in `Support.sol:299`
**Description**: When downgrading to a cheaper tier, the remaining time is converted using:
```solidity
uint256 converted = uint256(remaining) * oldPrice / newPrice;
```
This division rounds down, meaning the user receives slightly less converted time than they are owed. While this favors the protocol (acceptable), the combination of PM-1 favoring the user on upgrades and PM-2 favoring the protocol on downgrades creates an inconsistent rounding policy. A consistent rounding direction should be chosen.

**Proof of Concept**: User has 30 days (2592000 seconds) remaining on tier 2 ($25/mo) and downgrades to tier 1 ($10/mo). `converted = 2592000 * 2500000000 / 1000000000 = 6480000` seconds (75 days). No precision loss here. But with 2592001 seconds remaining: `2592001 * 2500000000 / 1000000000 = 6480002` (truncated from 6480002.5). The user loses 0.5 seconds.

**Recommendation**: Document the intended rounding direction for all division operations. If the protocol should always be favored, round down converted time on downgrades (current behavior) and round up cost on upgrades (fix PM-1).

---

## [PM-3] Discount calculation rounds down, allowing zero-cost subscriptions for very small amounts
**Severity**: Low
**Category**: evm-audit-precision-math
**Location**: `beforeSubscribe()` in `DiscountHook.sol:30`
**Description**: The discount formula is:
```solidity
adj.adjustedUSD = baseUSD * (100 - percentOff) / 100;
```
When `baseUSD * (100 - percentOff) < 100`, the result rounds to zero. This can happen if the tier price is extremely low (e.g., 1 in 8-decimal USD = $0.00000001/mo) and the discount is high (e.g., 99%). With `baseUSD = 1` and `percentOff = 99`: `1 * 1 / 100 = 0`. The user gets a free subscription.

Additionally, `percentOff = 100` is allowed by the setter validation (`_percentOff > 100` reverts), which always results in `adjustedUSD = 0`, making all qualifying subscriptions completely free.

**Proof of Concept**:
1. Owner sets `percentOff = 100`, `minMonths = 1`.
2. Any user calls `support()` with `duration >= 1`.
3. `adjustedUSD = baseUSD * 0 / 100 = 0`.
4. `_baseCost(0)` returns 0. Subscription is free.

**Recommendation**: If 100% discounts are not intended, change the validation to `>=`:
```solidity
if (_percentOff >= 100) revert InvalidDiscount();
```
For the rounding-to-zero case, consider adding a minimum cost check or reverting if the adjusted price rounds to zero when it should not:
```solidity
if (adj.adjustedUSD == 0 && baseUSD > 0 && percentOff < 100) {
    adj.adjustedUSD = 1; // minimum 1 unit
}
```

---

## [PM-4] Oracle decimal precision is hardcoded to 8 decimals
**Severity**: Medium
**Category**: evm-audit-precision-math
**Location**: `_usdToEth()` in `HasPriceFeed.sol:41` and `_beforeSubscribe()` in `Support.sol:359`
**Description**: The USD-to-ETH conversion in `HasPriceFeed._usdToEth()` assumes the Chainlink price feed returns 8-decimal precision:
```solidity
return usdAmount * 1e18 / uint256(price);
```
The `tierPrices` are stored as 8-decimal USD values (e.g., `500000000` = $5.00), and the formula `usdAmount * 1e18 / price` is only correct when `price` is also in 8 decimals. If the price feed is changed (via `setPriceFeed()`) to one with a different number of decimals (e.g., 18 decimals for some L2 feeds, or 6 decimals), the conversion will be off by orders of magnitude. There is no call to `feed.decimals()` to normalize.

**Proof of Concept**:
1. Owner deploys with a standard 8-decimal Chainlink ETH/USD feed. Works correctly.
2. Owner calls `setPriceFeed()` with a feed that returns 18 decimals (e.g., some custom or L2 feed).
3. For a $5 tier: `usdAmount = 500000000`, `price = 2000e18 = 2000000000000000000000`.
4. Result: `500000000 * 1e18 / 2000000000000000000000 = 250000000000000` (0.00025 ETH instead of the correct 0.0025 ETH).
5. Users pay 10x less than intended.

**Recommendation**: Query the feed's decimals and normalize:
```solidity
function _usdToEth(uint256 usdAmount) internal view virtual returns (uint256) {
    (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
    // ... staleness checks ...
    uint8 feedDecimals = priceFeed.decimals();
    return usdAmount * 1e18 / (uint256(price) * 10**(18 - feedDecimals));
}
```
Or, if the system is intended to only work with 8-decimal feeds, add a constructor check:
```solidity
require(priceFeed.decimals() == 8, "Only 8-decimal feeds supported");
```

---

## [PM-5] Division before multiplication in tier-change cost calculation
**Severity**: Medium
**Category**: evm-audit-precision-math
**Location**: `_changeTier()` in `Support.sol:289-291`
**Description**: In the tier upgrade path, the pro-rated USD difference is computed first via a division, then combined with `adj.adjustedUSD` before converting to ETH:
```solidity
uint256 diffUSD = uint256(newPrice - oldPrice) * remaining / 30 days;
required = _usdToEth(diffUSD + adj.adjustedUSD);
```
The division by `30 days` truncates `diffUSD` before it is passed to `_usdToEth()`, which then multiplies by `1e18` and divides by `price`. If the division were deferred, precision would be preserved. This is a division-before-multiplication pattern because `_usdToEth` internally performs `usdAmount * 1e18 / price`, and the already-truncated `diffUSD` is the input.

Concretely, the calculation is effectively:
```
((priceDiff * remaining) / 2592000 + adjustedUSD) * 1e18 / ethPrice
```
The intermediate `priceDiff * remaining / 2592000` loses precision that cannot be recovered by the subsequent multiplication by `1e18`.

**Proof of Concept**: Consider `newPrice - oldPrice = 100000000` (8-dec, $1/mo difference), `remaining = 100` seconds.
- Current: `diffUSD = 100000000 * 100 / 2592000 = 3858` (truncated from 3858.02...)
- Then `_usdToEth(3858) = 3858 * 1e18 / 200000000000 = 19290000000000` (0.00001929 ETH)
- If we kept full precision: `100000000 * 100 * 1e18 / (2592000 * 200000000000) = 19290123456790` (0.00001929012... ETH)
- Loss: ~123 wei per conversion

While each individual loss is tiny, this represents a structural precision leak.

**Recommendation**: Where possible, defer the division. For the ETH conversion, consider a specialized function that avoids intermediate truncation:
```solidity
uint256 numerator = uint256(newPrice - oldPrice) * remaining;
required = numerator * 1e18 / (uint256(30 days) * uint256(price)) + _baseCost(adj.adjustedUSD);
```
This keeps the full precision of the intermediate product before dividing.

---

## [PM-6] Tier change with very small remaining time rounds pro-rated cost to zero
**Severity**: Low
**Category**: evm-audit-precision-math
**Location**: `_changeTier()` in `Support.sol:289`
**Description**: When `uint256(newPrice - oldPrice) * remaining < 30 days` (2,592,000), the `diffUSD` rounds to zero. This means a user can upgrade their tier for free (paying only the `adj.adjustedUSD` from the hook, which may also be zero if `adjustedDuration` is 0). For a tier change with `duration = 0` (which is allowed: `if (duration == 0 && (isNew || tier == previousTier)) revert InvalidDuration()` only blocks same-tier or new subscriptions), the user gets a free tier upgrade.

**Proof of Concept**:
1. User subscribes to tier 0 ($5/mo) for 1 month.
2. After 29 days 23 hours 59 minutes 59 seconds (1 second remaining), user calls `support(recipient, 3, 0)` to change to tier 3 ($50/mo).
3. `remaining = 1`, `diffUSD = (5000000000 - 500000000) * 1 / 2592000 = 4500000000 / 2592000 = 1736` -- this is non-zero in this example. For it to be zero: `(newPrice - oldPrice) * remaining < 2592000`. With prices in 8-dec USD, even small differences (e.g., adjacent tiers with $5 difference = 500000000) make it hard to reach zero unless `remaining < 6` seconds.
4. With `remaining < 6` seconds and a $5 price difference: `500000000 * 5 / 2592000 = 964` (still non-zero). With `remaining = 0`: impossible since the token would be expired.

On further analysis, because tier prices are in 8-decimal USD (hundreds of millions), the numerator is always much larger than 2,592,000 for any `remaining >= 1`. The rounding-to-zero risk is negligible for realistic tier prices but could apply if tier prices are set extremely low (e.g., `tierPrices[0] = 1`, meaning $0.00000001/mo).

**Recommendation**: Add a check after computing `diffUSD`:
```solidity
if (diffUSD == 0 && newPrice > oldPrice) diffUSD = 1;
```
This ensures at least a minimal charge for upgrades, preventing free tier changes even with edge-case pricing.

---

## [PM-7] 30-day month approximation causes drift from calendar months
**Severity**: Info
**Category**: evm-audit-precision-math
**Location**: `_addDuration()` in `Support.sol:337` and `_changeTier()` in `Support.sol:289,300`
**Description**: Duration is computed as `duration * 30 days` (2,592,000 seconds), which approximates every month as exactly 30 days. Real calendar months vary from 28 to 31 days. Over a 12-month subscription, the total is 360 days instead of 365 (or 366), meaning the user gets ~5 fewer days than a calendar year. This is a well-known simplification in smart contract time calculations but should be documented so users understand what they are paying for.

The same constant appears in the pro-rata calculation in `_changeTier()`:
```solidity
uint256 diffUSD = uint256(newPrice - oldPrice) * remaining / 30 days;
```
This is consistent (same 30-day month assumption for both duration and pricing), so there is no internal inconsistency.

**Recommendation**: Document this behavior clearly in user-facing documentation and NatSpec comments:
```solidity
/// @dev Duration is measured in "months" of exactly 30 days (2,592,000 seconds).
///      A 12-month subscription lasts 360 days, not 365.
```
