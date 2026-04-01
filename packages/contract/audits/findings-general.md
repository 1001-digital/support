# General EVM Security Audit Findings

Audit of the Support subscription system contracts against the `evm-audit-general` checklist.

**Audited files:**
- `contracts/Support.sol`
- `contracts/SupportToken.sol`
- `contracts/extensions/WithSupportTokens.sol`
- `contracts/hooks/MaxSlotsHook.sol`
- `contracts/hooks/DiscountHook.sol`
- `contracts/interfaces/ISubscriptionHook.sol`
- `contracts/interfaces/ISupportRenderer.sol`
- `contracts/renderers/SupportRenderer.sol`

---

## [G-1] Returndata bombing on excess refund call to untrusted address
**Severity**: Low
**Category**: evm-audit-general
**Location**: `Support.support()` at `contracts/Support.sol:156`
**Description**: When refunding excess ETH to `msg.sender`, the contract uses `.call{value: excess}("")`. If `msg.sender` is a malicious contract, it can return a massive `bytes` payload in its `receive()`/`fallback()` function. Solidity automatically copies all returndata into memory, which consumes gas quadratically. This can grief the caller by wasting most of the remaining gas on memory allocation, potentially causing the transaction to fail with an out-of-gas error. The same pattern appears in `withdraw()` at line 247 but the recipient there is `owner()` (trusted).
**Proof of Concept**: 1. Deploy an attacker contract whose `receive()` returns megabytes of data via assembly. 2. Call `support()` from the attacker contract with excess ETH. 3. The refund call at line 156 copies the massive returndata, consuming gas quadratically and potentially causing the transaction to revert.
**Recommendation**: Use inline assembly to limit the returndata copy size:
```solidity
uint256 excess = msg.value - required;
if (excess > 0) {
    bool sent;
    assembly {
        sent := call(gas(), caller(), excess, 0, 0, 0, 0)
    }
    if (!sent) revert TransferFailed();
}
```

---

## [G-2] Unbounded loop with external calls in MaxSlotsHook can cause DoS
**Severity**: Medium
**Category**: evm-audit-general
**Location**: `MaxSlotsHook.onSubscribe()` at `contracts/hooks/MaxSlotsHook.sol:65-72` and `_canSubscribe()` at lines 130-134
**Description**: When all slots are occupied, `onSubscribe()` iterates over the entire `_tierHolders` array (up to `maxSlots[tier]`, a `uint16` supporting up to 65535 entries). Each iteration calls `_isActiveOnTier()`, which makes two external calls to the Support contract (`activeTokenOf` and `currentTier`). Additionally, `_canSubscribe()` performs the same loop and is called during `beforeSubscribe()`. This means the full loop executes twice per subscription when slots are full: once in `beforeSubscribe()` (view) and once in `onSubscribe()` (state-modifying). With large `maxSlots` values, this can exceed the block gas limit, permanently blocking new subscriptions for that tier.
**Proof of Concept**: 1. Owner sets `maxSlots[0] = 1000`. 2. 1000 subscribers fill all slots. 3. When all 1000 are active, any new subscriber triggers 2000 external calls (1000 in `_canSubscribe` + 1000 in `onSubscribe`), likely exceeding gas limits.
**Recommendation**: Set a reasonable upper bound on `maxSlots` in `setMaxSlots()`, for example a maximum of 256. Alternatively, maintain a counter of active holders instead of scanning the full array:
```solidity
function setMaxSlots(uint8 tier, uint16 max) external onlyOwner {
    if (tier >= 4) revert InvalidTier();
    if (max > 256) revert MaxSlotsTooHigh(); // add a reasonable cap
    maxSlots[tier] = max;
    emit MaxSlotsUpdated(tier, max);
}
```

---

## [G-3] No reentrancy guard on payable `support()` function
**Severity**: Low
**Category**: evm-audit-general
**Location**: `Support.support()` at `contracts/Support.sol:112-159`
**Description**: The `support()` function makes multiple external calls: (1) `_beforeSubscribe()` calls the hook's `beforeSubscribe()` (view), (2) `_notifyHook()` calls `h.onRelease()` and `h.onSubscribe()` (state-modifying), and (3) the excess refund sends ETH to `msg.sender` via `.call`. While the code broadly follows the checks-effects-interactions pattern (state is updated in `_applySubscription` before hook notification and refund), there is no `nonReentrant` guard. If a malicious caller re-enters during the excess refund, they could call `support()` again with a different recipient. The hook contract set by the owner is semi-trusted, but a malicious or compromised hook could exploit intermediate state during `onSubscribe`/`onRelease` callbacks.
**Proof of Concept**: 1. Attacker deploys a contract that calls `support()` from its `receive()` function. 2. Attacker calls `support()` with excess ETH. 3. During the excess refund at line 156, the attacker's `receive()` re-enters `support()`. 4. While state is updated at this point, the attacker gets an additional subscription call before the first call's event is emitted.
**Recommendation**: Add OpenZeppelin's `ReentrancyGuard` and apply `nonReentrant` to `support()`:
```solidity
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

abstract contract Support is Ownable2Step, HasPriceFeed, WithSaleStart, ReentrancyGuard {
    function support(...) external payable afterSaleStart nonReentrant {
```

---

## [G-4] Downgrading to a free tier ($0 price) does not convert remaining value into extended time
**Severity**: Medium
**Category**: evm-audit-general
**Location**: `Support._changeTier()` at `contracts/Support.sol:297-301`
**Description**: When a subscriber downgrades to a tier with `tierPrices[toTier] == 0`, the conversion formula at line 297-298 sets `converted = uint256(remaining)`, meaning the subscriber keeps only the same number of seconds remaining. This means a user who paid for an expensive tier (e.g., $50/mo Partner) and downgrades to a free tier ($0/mo Supporter) loses all the dollar-value they prepaid. For example, a user with 15 days remaining on a $50/mo tier should logically receive infinite (or capped) time on a $0/mo tier, but instead receives only 15 days. This is a silent loss of value for users and contradicts the conversion logic used for non-zero tier downgrades, which proportionally extends time.
**Proof of Concept**: 1. User subscribes to tier 3 ($50/mo) for 1 month, paying ~$50 worth of ETH. 2. After 15 days, user downgrades to tier 0 ($0/mo free). 3. User receives only 15 days on the free tier instead of the proportional value remaining. 4. The ~$25 of remaining value is effectively lost.
**Recommendation**: When `newPrice == 0`, cap the converted duration at `type(uint64).max` or a large value rather than just using `remaining`:
```solidity
uint256 converted = newPrice == 0
    ? type(uint64).max  // free tier: give maximum time
    : uint256(remaining) * oldPrice / newPrice;
```
Alternatively, if the intent is to not extend time on free tiers, document this clearly and emit an event so users understand the trade-off.

---

## [G-5] PUSH0 opcode incompatibility with some L2s and alt-chains
**Severity**: Low
**Category**: evm-audit-general
**Location**: All contract files, `pragma solidity ^0.8.28`
**Description**: All contracts use `pragma solidity ^0.8.28`. Solidity versions >= 0.8.20 emit the `PUSH0` opcode by default. This opcode is not supported on several L2 networks and alternative EVM chains (e.g., older versions of Arbitrum, zkSync Era, some Polygon zkEVM versions). If these contracts are intended for multi-chain deployment, they will fail to execute on chains that do not support `PUSH0`.
**Proof of Concept**: Compile and attempt to deploy to a chain that does not support `PUSH0` (e.g., zkSync Era). The deployment will fail or the contract will behave unexpectedly.
**Recommendation**: If multi-chain deployment is planned, either target the EVM version explicitly in the compiler settings (`evmVersion: "paris"` which uses `PUSH0`, or `"shanghai"`) or use an older Solidity version. If only deploying to mainnet and L2s that support Shanghai, this is informational only.

---

## [G-6] `withdraw()` uses `address(this).balance` which includes force-fed ETH
**Severity**: Info
**Category**: evm-audit-general
**Location**: `Support.withdraw()` at `contracts/Support.sol:244-250`
**Description**: The `withdraw()` function sends `address(this).balance` to the owner. ETH can be force-fed to the contract via `selfdestruct`, pre-computed CREATE2 addresses, or coinbase rewards, inflating the balance beyond what was collected from subscriptions. In this contract, this is not exploitable because the owner receives all funds regardless, and there is no accounting invariant that depends on balance matching collected payments. However, the `Withdrawal` event at line 249 may log an amount that does not match the sum of subscription payments, which could confuse off-chain accounting.
**Proof of Concept**: 1. Force-send 1 ETH via `selfdestruct` to the Support contract. 2. Owner calls `withdraw()`. 3. Owner receives subscription payments plus the force-fed 1 ETH. 4. The `Withdrawal` event amount does not match the sum of `Supported` event payments.
**Recommendation**: This is informational. If accurate accounting is important, track collected payments in a state variable and withdraw only that amount:
```solidity
uint256 public collectedPayments;
// In support(): collectedPayments += required;
// In withdraw(): use collectedPayments instead of address(this).balance
```

---

## [G-7] Hook external calls during `support()` can revert and block subscriptions
**Severity**: Medium
**Category**: evm-audit-general
**Location**: `Support._notifyHook()` at `contracts/Support.sol:273-279` and `Support._beforeSubscribe()` at lines 356-364
**Description**: The `support()` function makes external calls to the hook contract at two points: `beforeSubscribe()` (view call) and `onSubscribe()`/`onRelease()` (state-modifying calls). If the hook contract reverts for any reason (bug, gas limit, intentional blocking), all subscriptions are blocked. The hook is set by the owner, so this is a trust assumption. However, if the hook contract is upgradeable, compromised, or has a bug that causes it to revert under certain conditions, it creates a denial-of-service for all subscribers. There is no try/catch wrapper, no fallback mechanism, and no emergency way to bypass the hook without the owner calling `setHook(address(0))`.
**Proof of Concept**: 1. Owner sets a hook contract. 2. The hook contract has a bug that causes `onSubscribe()` to revert for a specific tier. 3. All subscriptions to that tier are permanently blocked until the owner notices and updates or removes the hook.
**Recommendation**: Consider wrapping hook calls in a try/catch so that a failing hook does not block subscriptions. At minimum, document this risk. A safer pattern:
```solidity
function _notifyHook(ISubscriptionHook h, uint8 previousTier, uint8 tier, address recipient) internal {
    if (address(h) == address(0)) return;
    if (previousTier != type(uint8).max && previousTier != tier) {
        try h.onRelease(previousTier, recipient) {} catch {}
    }
    try h.onSubscribe(tier, recipient) {} catch {}
}
```
Note: this changes the security model -- a reverting hook can no longer block subscriptions (e.g., MaxSlotsHook's TierFull revert would be swallowed). Consider making this behavior configurable or having a separate "mandatory" vs "optional" hook pattern.

---

## [G-8] MaxSlotsHook `_canSubscribe` and `onSubscribe` can diverge due to state changes between calls
**Severity**: Medium
**Category**: evm-audit-general
**Location**: `MaxSlotsHook.beforeSubscribe()` at `contracts/hooks/MaxSlotsHook.sol:39-46` and `MaxSlotsHook.onSubscribe()` at lines 52-75
**Description**: The `beforeSubscribe()` function calls `_canSubscribe()` to check if a slot is available (view call). Later, `onSubscribe()` is called to actually assign the slot. Between these two calls, the Support contract calls `_applySubscription()` which modifies state (updating `activeToken`, `expiresAt`, segments). This means the `_isActiveOnTier()` checks in `_canSubscribe()` and `onSubscribe()` may see different state. Specifically, if the subscriber's token state changes between the two calls (e.g., a new active token is set, changing their tier), `_canSubscribe()` may return true while `onSubscribe()` reverts with `TierFull()`, or vice versa. This is a time-of-check-time-of-use (TOCTOU) issue.
**Proof of Concept**: 1. Tier 0 has maxSlots = 2, with 2 active holders. 2. One holder's subscription has just expired but `_isActiveOnTier` still returns true because `activeTokenOf` returns a different active token on the same tier. 3. `_canSubscribe` finds an inactive slot, returns true. 4. Between `beforeSubscribe` and `onSubscribe`, `_applySubscription` updates the subscriber's state. 5. `onSubscribe` re-scans and may now see different results for `_isActiveOnTier` due to the changed `activeToken` mapping.
**Recommendation**: Consider combining the check-and-assign into a single `onSubscribe` call, or accept the TOCTOU gap as a design trade-off since both calls happen in the same transaction and the state changes between them are limited to the subscriber being processed.

---

## [G-9] `MaxSlotsHook.onSubscribe` and `onRelease` lack access control beyond `onlySupport`
**Severity**: Low
**Category**: evm-audit-general
**Location**: `MaxSlotsHook.onSubscribe()` at `contracts/hooks/MaxSlotsHook.sol:52` and `onRelease()` at line 77
**Description**: The `onSubscribe` and `onRelease` functions are protected by `onlySupport`, meaning only the Support contract can call them. However, the Support contract calls `onRelease` before `onSubscribe` in `_notifyHook()`. If the hook's `onSubscribe` reverts (e.g., `TierFull`), the `onRelease` has already executed, removing the subscriber from their previous tier. This is not rolled back because the entire transaction reverts. Wait -- actually, since `onRelease` and `onSubscribe` are called in the same transaction, a revert in `onSubscribe` WILL roll back the `onRelease` state change. So this is fine. However, a more subtle issue: `_notifyHook` calls `onSubscribe` unconditionally for every subscription action (including extensions at the same tier). `MaxSlotsHook.onSubscribe` handles this with the early return at line 55 (`if (_tierHolderIndex[tier][subscriber] != 0) return`), but other hook implementations might not be as careful.
**Proof of Concept**: This is a defense-in-depth concern for future hook implementations rather than a concrete exploit on current code.
**Recommendation**: Consider documenting in the `ISubscriptionHook` interface that `onSubscribe` may be called multiple times for the same subscriber on the same tier (for extensions), and implementations must handle this idempotently.

---

## [G-10] Tier change to same-priced tier follows downgrade path instead of no-op
**Severity**: Low
**Category**: evm-audit-general
**Location**: `Support._changeTier()` at `contracts/Support.sol:289-301`
**Description**: When changing between two tiers that have equal prices (e.g., both are $10/mo), the condition `newPrice > oldPrice` at line 289 is false, so the code follows the downgrade path. In the equal-price case, `converted = remaining * oldPrice / newPrice = remaining`, which is correct (time stays the same). However, the subscriber is still charged `_baseCost(adj.adjustedUSD)` at line 296, where `adjustedUSD` is based on `tierPrices[tier] * duration`. Since tier changes allow `duration == 0`, the cost could be 0. But if `duration > 0` is passed, the subscriber pays for additional months AND keeps their remaining time, effectively getting more value than intended compared to the upgrade path where the additional duration cost is added to the differential. This inconsistency between the upgrade and downgrade/equal paths could be confusing.
**Proof of Concept**: 1. Two tiers both priced at $10/mo. 2. Subscriber on tier A with 20 days remaining calls `_changeTier` to tier B with `duration = 1`. 3. Subscriber pays for 1 month AND keeps the 20 days remaining. 4. If tier B were $1 more expensive, the upgrade path would charge the differential plus the monthly cost, giving a different result.
**Recommendation**: Document this behavior explicitly, or add a separate code path for equal-price tier changes that applies the same logic as the upgrade path (charge differential of $0 + additional months).

---

## [G-11] `_changeTier` upgrade path charges pro-rated differential using raw seconds instead of monthly fractions
**Severity**: Low
**Category**: evm-audit-general
**Location**: `Support._changeTier()` at `contracts/Support.sol:290`
**Description**: The upgrade cost formula `uint256(newPrice - oldPrice) * remaining / 30 days` computes the USD cost by treating `remaining` as raw seconds and dividing by `30 days` (2592000 seconds). Tier prices are per-month values. The calculation is mathematically correct for pro-rating, but `30 days` is a fixed approximation of a month (not a calendar month). Since subscriptions also use `30 days` as the month length in `_addDuration()`, this is internally consistent. However, `remaining` could be a value that is not a clean multiple of `30 days` (e.g., if a hook adjusted the start time or previous tier changes created odd remainders), leading to small rounding losses in the pro-rated amount. This always rounds down (in favor of the subscriber), so it is not exploitable but creates minor accounting imprecision.
**Proof of Concept**: Subscriber has exactly 15 days + 1 second remaining. The differential for the remaining 1 second is `(newPrice - oldPrice) * 1 / 2592000`, which rounds to 0 for small price differences, giving the subscriber a free second of the more expensive tier.
**Recommendation**: Informational. The rounding always favors the subscriber, which is a safe default. No change needed unless exact accounting is required.

---

## [G-12] `DiscountHook.onSubscribe` and `onRelease` are no-ops without access control
**Severity**: Info
**Category**: evm-audit-general
**Location**: `DiscountHook.onSubscribe()` at `contracts/hooks/DiscountHook.sol:40` and `onRelease()` at line 41
**Description**: Unlike `MaxSlotsHook`, the `DiscountHook` does not restrict `onSubscribe` and `onRelease` to be callable only by the Support contract. Anyone can call these functions, though they are no-ops (empty function bodies). This is not a security issue since the functions do nothing, but it deviates from the `MaxSlotsHook` pattern and could become a problem if the functions are later given a body without adding access control.
**Proof of Concept**: Any address can call `discountHook.onSubscribe(0, address(0))` without error.
**Recommendation**: Add `onlySupport` (or similar) modifiers for consistency with `MaxSlotsHook`, even though the functions are currently no-ops:
```solidity
address public immutable support;
modifier onlySupport() { require(msg.sender == support); _; }

function onSubscribe(uint8, address) external override onlySupport {}
function onRelease(uint8, address) external override onlySupport {}
```

---

## [G-13] `DiscountHook` allows setting `percentOff = 100`, making subscriptions free
**Severity**: Low
**Category**: evm-audit-general
**Location**: `DiscountHook.setDiscount()` at `contracts/hooks/DiscountHook.sol:43-48` and constructor at lines 18-21
**Description**: The `percentOff` parameter accepts values up to and including 100 (`if (_percentOff > 100) revert`). Setting `percentOff = 100` means `adjustedUSD = baseUSD * (100 - 100) / 100 = 0`, making all qualifying subscriptions free. While the owner may intentionally want to offer free subscriptions, this bypasses the `grant()` function's purpose and could be set accidentally. Combined with a `minMonths = 1`, this would make all subscriptions completely free.
**Proof of Concept**: 1. Owner calls `setDiscount(1, 100)`. 2. Any user can now subscribe to any tier for any duration (>= 1 month) at zero cost.
**Recommendation**: Consider whether 100% discount is intended. If not, change the check to `if (_percentOff >= 100) revert InvalidDiscount();`. If it is intended, document this behavior.

---

## [G-14] `WithSupportTokens._activeTokenOf` iterates all tokens owned by a supporter
**Severity**: Low
**Category**: evm-audit-general
**Location**: `WithSupportTokens._activeTokenOf()` at `contracts/extensions/WithSupportTokens.sol:148-163`
**Description**: When the cached `activeToken` for a supporter is expired or zero, the function falls back to iterating ALL tokens owned by the supporter via `balanceOf` and `tokenOfOwnerByIndex`. If a supporter accumulates many expired NFT tokens (they can receive unlimited support tokens via third-party subscriptions or transfers), this scan becomes expensive. Since `_activeTokenOf` is called indirectly during `support()` (via `_syncActiveToken` -> `_resolveSubscription`), a supporter with many tokens could face increasingly expensive subscription transactions.
**Proof of Concept**: 1. A supporter receives 500 NFT tokens via transfers (all expired). 2. Supporter calls `support()` to create a new subscription. 3. `_activeTokenOf` iterates all 500 tokens before concluding none are active, consuming significant gas.
**Recommendation**: Consider adding a cap on the scan or maintaining a more efficient data structure for active token lookup. Alternatively, allow users to manually clear their `activeToken` pointer.

---

## [G-15] `_mint` used instead of `_safeMint` -- tokens may be locked in non-ERC721-receiver contracts
**Severity**: Info
**Category**: evm-audit-general
**Location**: `WithSupportTokens._onNewSubscription()` at `contracts/extensions/WithSupportTokens.sol:141`
**Description**: The contract uses `_mint` instead of `_safeMint` when creating new subscription tokens. `_safeMint` calls `onERC721Received` on the recipient if it is a contract, ensuring the recipient can handle ERC721 tokens. With `_mint`, tokens can be sent to contracts that do not implement the ERC721 receiver interface, permanently locking the token. However, since subscriptions are tied to addresses (not tokens), a locked token does not prevent the recipient from getting a new subscription -- it just means the NFT representation is inaccessible. Additionally, using `_mint` avoids a reentrancy vector (no `onERC721Received` callback).
**Proof of Concept**: 1. Call `support(contractAddress, 0, 1)` where `contractAddress` is a contract without `onERC721Received`. 2. The token is minted to the contract but can never be transferred out.
**Recommendation**: This appears to be an intentional design choice to avoid reentrancy. Document that `_mint` is used deliberately. If ERC721 receiver checking is desired, use `_safeMint` with a reentrancy guard.
