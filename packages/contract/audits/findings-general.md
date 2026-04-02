# General Solidity/EVM Security Audit Findings

**Scope**: Support.sol, SupportToken.sol, WithSupportTokens.sol, SupportRenderer.sol, DiscountHook.sol, EvmNowSupporterHook.sol, MaxSlotsHook.sol, and all interfaces.

**Compiler**: Solidity ^0.8.28

**Date**: 2026-04-02

---

## [G-1] Reentrancy in `support()` via excess ETH refund before full state settlement
**Severity**: Medium
**Category**: evm-audit-general
**Location**: `support()` in Support.sol:154-158
**Description**: The `support()` function refunds excess ETH to `msg.sender` via a low-level `.call{value: excess}("")` at line 156. While all core state updates (`_applySubscription`, `_notifyHook`, `_afterSubscriptionChange`, and the `Supported` event) complete before the refund, there is no reentrancy guard on the function. If `msg.sender` is a contract, its `receive()`/`fallback()` can re-enter `support()`. On re-entry, `_resolveSubscription` will read the already-updated state, so the attacker cannot double-spend. However, the lack of a `nonReentrant` modifier means defense relies entirely on the correctness of the checks-effects-interactions pattern holding across all future code changes and hook implementations. This is a latent risk rather than an immediately exploitable bug.

Additionally, external hook calls (`_notifyHook` at line 150) execute before the refund, meaning a malicious hook contract could cause unexpected behavior during the state between hook notification and refund completion.

**Proof of Concept**: Deploy an attacker contract that calls `support()` with excess ETH. In the attacker's `receive()`, re-enter `support()`. Currently, the re-entrant call would process correctly because state is updated before the refund. The risk is latent: if any future state change is added after the refund, or if hook contracts introduce shared mutable state, the lack of a guard becomes exploitable.

**Recommendation**: Add OpenZeppelin's `ReentrancyGuard` and apply `nonReentrant` to `support()`:
```solidity
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

abstract contract Support is Ownable2Step, HasPriceFeed, WithSaleStart, ReentrancyGuard {
    function support(...) external payable nonReentrant afterSaleStart {
```

---

## [G-2] `withdraw()` uses `address(this).balance` which can be inflated via force-feeding
**Severity**: Low
**Category**: evm-audit-general
**Location**: `withdraw()` in Support.sol:239-245
**Description**: The `withdraw()` function sends `address(this).balance` to the owner. ETH can be force-fed to the contract via `selfdestruct` from another contract, pre-computed CREATE2 addresses, or coinbase rewards. Since there is no `receive()`/`fallback()` function, normal ETH transfers will revert, but `selfdestruct` bypasses this. The inflated balance means `withdraw()` would send more ETH than was actually collected through subscriptions.

In this case, this is not harmful -- it benefits the owner who receives extra ETH. However, if any future logic relies on `address(this).balance` matching expected subscription revenue, it would break. The contract does not currently use balance-based invariants beyond withdrawal, so the practical impact is limited.

**Proof of Concept**: Deploy a contract with `selfdestruct(payable(supportContract))` to force-feed 1 ETH. The owner's next `withdraw()` call will include this extra ETH.

**Recommendation**: Consider tracking collected revenue in an internal variable instead of relying on `address(this).balance`:
```solidity
uint256 public collectedRevenue;

// In support():
collectedRevenue += required;

// In withdraw():
uint256 amount = collectedRevenue;
collectedRevenue = 0;
(bool sent, ) = owner().call{value: amount}("");
```

---

## [G-3] `addTier()` silently truncates tier index when more than 256 tiers exist
**Severity**: Low
**Category**: evm-audit-general
**Location**: `addTier()` in Support.sol:226-230
**Description**: The `addTier()` function casts `tierPrices.length - 1` to `uint8` in the `TierPriceUpdated` event at line 229. If more than 256 tiers are added, the cast silently wraps, emitting an incorrect tier index in the event. More critically, the tier parameter in `support()`, `grant()`, and throughout the system is `uint8`, meaning tiers beyond index 255 are unreachable by users despite existing in the `tierPrices` array. The `support()` function's check `tier >= tierPrices.length` uses `uint8 tier` which can never exceed 255, so tiers 256+ would be dead entries consuming storage.

**Proof of Concept**: Call `addTier()` 257 times. The 257th tier (index 256) exists in `tierPrices` but can never be selected because the `tier` parameter is `uint8` (max 255). The event for this tier would emit `tier = 0` (wrapped).

**Recommendation**: Add a cap check in `addTier()`:
```solidity
function addTier(uint128 priceUSD) external onlyOwner {
    if (priceUSD == 0) revert InvalidPrice();
    if (tierPrices.length >= type(uint8).max) revert InvalidTier();
    tierPrices.push(priceUSD);
    emit TierPriceUpdated(uint8(tierPrices.length - 1), priceUSD);
}
```

---

## [G-4] `safeTransferFrom` on the ERC-721 token triggers `onERC721Received` callback, creating a reentrancy vector during token transfer
**Severity**: Low
**Category**: evm-audit-general
**Location**: `_update()` in WithSupportTokens.sol:66-87, and OpenZeppelin ERC721.safeTransferFrom
**Description**: When a token is transferred via `safeTransferFrom`, the OpenZeppelin ERC721 calls `_update()` (which runs the `WithSupportTokens._update()` override including hook calls at lines 81-83), then calls `checkOnERC721Received()` on the recipient. If the recipient is a contract, its `onERC721Received` callback can re-enter the Support system. At that point, the subscription state has been updated (subscription mapping reassigned, hooks notified), but the callback occurs before `safeTransferFrom` returns to the caller. No reentrancy guard is present.

The hook's external calls (`h.onRelease`, `h.onSubscribe`) at lines 81-83 are also made to a potentially owner-controlled but still external contract, compounding the attack surface during transfers.

**Proof of Concept**: Transfer a token via `safeTransferFrom` to a malicious contract. The contract's `onERC721Received` re-enters `support()` to manipulate subscription state. Since subscription state is already updated, direct exploitation is limited, but cross-contract reentrancy (e.g., with MaxSlotsHook reading stale data) could be possible.

**Recommendation**: Add a reentrancy guard to the `_update` function or to the entire contract using OpenZeppelin's `ReentrancyGuard`. Alternatively, document that hooks MUST NOT call back into the Support contract.

---

## [G-5] Malicious or buggy hook can permanently DoS all subscriptions
**Severity**: Medium
**Category**: evm-audit-general
**Location**: `_beforeSubscribe()` in Support.sol:338-346, `_notifyHook()` in Support.sol:268-274
**Description**: The `support()` function makes three external calls to the hook contract: `beforeSubscribe()` (line 128-130), `onRelease()` (line 271), and `onSubscribe()` (line 273). If the hook contract reverts on any of these calls, the entire `support()` transaction reverts. A malicious or buggy hook can therefore permanently block all new subscriptions and renewals.

The `grant()` function (owner-only) also calls `_notifyHook()` at line 175, so even the owner cannot grant subscriptions if the hook reverts.

The owner can call `setHook(ISubscriptionHook(address(0)))` to disable the hook, but this is a manual recovery step that requires awareness of the issue. During the window between hook failure and owner intervention, the system is fully DoS'd.

**Proof of Concept**: Owner sets a hook that later gets paused or has a bug causing `revert` in `beforeSubscribe()`. All calls to `support()` and `grant()` revert. The owner must notice and call `setHook(address(0))` to recover.

**Recommendation**: Wrap hook calls in try/catch to make them non-blocking, or at minimum wrap `onSubscribe`/`onRelease` (which are post-state-change notifications) in try/catch:
```solidity
function _notifyHook(ISubscriptionHook h, uint8 previousTier, uint8 tier, address recipient) internal {
    if (address(h) == address(0)) return;
    if (previousTier != NO_TIER && previousTier != tier) {
        try h.onRelease(previousTier, recipient) {} catch {}
    }
    try h.onSubscribe(tier, recipient) {} catch {}
}
```
Note: `beforeSubscribe` should remain reverting since it returns pricing adjustments that must be valid.

---

## [G-6] Returndata bombing on excess ETH refund call
**Severity**: Low
**Category**: evm-audit-general
**Location**: `support()` in Support.sol:156
**Description**: The refund at line 156 uses `msg.sender.call{value: excess}("")`. If `msg.sender` is a contract, it can return a massive `bytes` payload in its `receive()`/`fallback()`. Solidity automatically copies all returndata into memory, consuming gas quadratically. This can grief the caller by wasting gas, though the transaction would still succeed (the refund check passes). The same pattern exists in `withdraw()` at line 242, though there the recipient is the trusted owner.

**Proof of Concept**: Deploy an attacker contract whose `receive()` returns 100KB of data via assembly. Call `support()` with overpayment. The refund call at line 156 copies 100KB from returndata, consuming significant gas.

**Recommendation**: Use assembly to limit returndata copy size:
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

## [G-7] `_changeTier` time conversion is lossy -- downgrading to a cheaper tier loses subscription time to rounding
**Severity**: Low
**Category**: evm-audit-general
**Location**: `_changeTier()` in Support.sol:286
**Description**: The tier change calculation at line 286 converts remaining time using `uint256(remaining) * oldPrice / newPrice`. This integer division truncates. When downgrading from a cheaper to a more expensive tier (or when prices don't divide evenly), the user loses subscription time to rounding.

For example: a user has 45 days remaining on a tier priced at 500 (cents). They upgrade to a tier priced at 700. The converted time is `45 * 500 / 700 = 32` days (actual: 32.14 days). The user loses ~0.14 days. With larger price ratios, the loss grows.

**Proof of Concept**: Subscribe at tier 0 (price 500) for 3 months (90 days). After 45 days, upgrade to tier 1 (price 700) with duration 0. Remaining = 45 days. Converted = 45 * 500 / 700 = 32 days. Lost: ~3.4 hours.

**Recommendation**: This is inherent to integer division and the amounts lost are small. Consider documenting this behavior or using higher precision intermediate calculations (e.g., multiply by 1e18 then divide back).

---

## [G-8] `MaxSlotsHook.onSubscribe()` iterates unbounded array, risking gas limit DoS
**Severity**: Medium
**Category**: evm-audit-general
**Location**: `onSubscribe()` in MaxSlotsHook.sol:60-67
**Description**: When the `_tierHolders[tier]` array is full (length == maxSlots), `onSubscribe()` iterates through ALL holders at lines 60-67 to find an expired one to replace. Each iteration makes two external calls to the Support contract (`subscription()` and `currentTier()` via `_isActiveOnTier()`). If `maxSlots` is set to a large value (e.g., 1000), this loop makes up to 2000 external calls, which will exceed the block gas limit and permanently DoS subscriptions for that tier.

The same issue affects `_canSubscribe()` (lines 126-129) and `activeTierHolders()` (lines 103-115).

**Proof of Concept**: Set `maxSlots[0] = 500`. Fill tier 0 with 500 active subscribers. When subscriber 501 tries to subscribe and the loop must check all 500, the gas cost (~2000 SLOAD-equivalent external calls at ~2600 gas each = ~5.2M gas just for the calls) approaches block gas limit.

**Recommendation**: Maintain a counter of active holders per tier, or implement a lazy cleanup mechanism that tracks the last-checked index instead of iterating from zero each time. Alternatively, enforce a reasonable maximum for `maxSlots`:
```solidity
function setMaxSlots(uint8 tier, uint16 max) external onlyOwner {
    require(max <= 100, "Max slots too high");
    maxSlots[tier] = max;
    emit MaxSlotsUpdated(tier, max);
}
```

---

## [G-9] Subscription can be transferred to an address that already has a different subscription, orphaning the recipient's existing subscription
**Severity**: Medium
**Category**: evm-audit-general
**Location**: `_update()` in WithSupportTokens.sol:76
**Description**: The `OnePerWallet` extension prevents an address from holding more than one token. However, if address A holds token 1 (with an active subscription) and address B holds token 2 (also active), B can transfer token 2 to A only if A first transfers token 1 away. But there is a subtler issue: at line 76, `subscription[to] = tokenId` unconditionally overwrites the recipient's subscription mapping. If the recipient previously had a subscription that expired (token still owned but subscription inactive), and then receives a new token via transfer, their old `subscription` mapping is overwritten. The old token's subscription data (`startedAt`, `expiresAt`, `tierHistory`) remains in storage but is no longer linked to any address.

More critically, the `_update` hook at line 76 sets `subscription[to] = tokenId` for the incoming token, but if `to` already had a different `subscription[to]` value pointing to another token they own... the `OnePerWallet` constraint prevents this for active tokens, but edge cases with expired tokens could cause state inconsistency.

**Proof of Concept**: 
1. Alice subscribes, gets token 1, subscription expires
2. Bob subscribes, gets token 2, still active
3. Alice transfers token 1 to someone else (or it was already transferred)
4. Bob transfers token 2 to Alice
5. `subscription[Alice]` is now token 2; token 1's data is orphaned

**Recommendation**: In the `_update` hook, verify that the recipient does not already have an active subscription mapped to a different token:
```solidity
if (to != address(0)) {
    uint256 existingSub = subscription[to];
    // Only allow if no existing active subscription or same token
    require(existingSub == 0 || existingSub == tokenId || block.timestamp >= expiresAt[existingSub], "Active sub exists");
}
```

---

## [G-10] PUSH0 opcode compatibility concern with Solidity ^0.8.28
**Severity**: Info
**Category**: evm-audit-general
**Location**: All contracts, `pragma solidity ^0.8.28`
**Description**: Solidity >=0.8.20 emits the `PUSH0` opcode by default. This opcode is supported on Ethereum mainnet (post-Shanghai) and most major L2s (Arbitrum, Optimism, Base) as of 2025. However, some chains (e.g., older zkSync versions, some alt-L1s) may not support it. If the contract is intended for deployment on chains that do not support PUSH0, compilation will produce incompatible bytecode.

**Proof of Concept**: Compile with Solidity 0.8.28 and inspect bytecode for PUSH0 (0x5f). Deploy to a chain that does not support it -- deployment will fail.

**Recommendation**: If multi-chain deployment is planned, verify PUSH0 support on all target chains. If needed, use `--evm-version paris` in the compiler settings to avoid PUSH0.

---

## [G-11] `DiscountHook.setDiscount()` allows setting `percentOff = 100`, making subscriptions free
**Severity**: Low
**Category**: evm-audit-general
**Location**: `setDiscount()` in DiscountHook.sol:47-52
**Description**: The validation `if (_percentOff > 100) revert InvalidDiscount()` allows `percentOff = 100`. When this is set and the duration meets `minMonths`, `adjustedUSD` becomes `baseUSD * 0 / 100 = 0`, making the subscription free. While this may be intentional for promotional use, it could also be an off-by-one if the intent was to cap at 99%.

Combined with `minMonths = 0`, ALL subscriptions become free regardless of duration, which would drain the system's revenue model.

**Proof of Concept**: Owner calls `setDiscount(0, 100)`. All subscriptions now have `adjustedUSD = 0`, requiring 0 ETH payment.

**Recommendation**: If 100% discount is not intended, change the check to `>= 100`. If it is intended, add a separate `minMonths > 0` validation to prevent the zero-months edge case:
```solidity
if (_percentOff >= 100) revert InvalidDiscount();
// or if 100% is OK:
if (_percentOff > 100) revert InvalidDiscount();
if (_percentOff == 100 && _minMonths == 0) revert InvalidDiscount();
```

---

## [G-12] Hook's `adjustedStart` can be set to any past timestamp, creating backdated subscriptions with distorted `startedAt`
**Severity**: Low
**Category**: evm-audit-general
**Location**: `support()` in Support.sol:138
**Description**: The `beforeSubscribe` hook can return an `adjustedStart` value that sets the subscription's `startedAt` to any timestamp, including one in the distant past or future. At line 138, `if (adj.adjustedStart != 0) start = adj.adjustedStart;` unconditionally accepts the hook's timestamp. A backdated start combined with a normal expiry would create a subscription that appears to have been active for longer than it actually was (affecting tier history display and renderer calculations). A future-dated start would create a subscription where `startedAt > block.timestamp`, causing underflow in the renderer's `_buildSVG` at line 54: `block.timestamp - data.startedAt`.

This is trust-model dependent -- the hook is set by the owner, so a malicious hook implies a compromised owner. However, a buggy hook could inadvertently cause the renderer to revert.

**Proof of Concept**: Deploy a hook that returns `adjustedStart = block.timestamp + 365 days`. Subscribe. Call `tokenURI()` -- the renderer computes `block.timestamp - data.startedAt` which underflows and reverts (Solidity 0.8.x checked arithmetic).

**Recommendation**: Validate `adjustedStart` in `support()`:
```solidity
if (adj.adjustedStart != 0) {
    if (adj.adjustedStart > block.timestamp) revert InvalidDuration();
    start = adj.adjustedStart;
}
```

---

## [G-13] `grant()` allows owner to set a past `startAt` timestamp, potentially causing renderer underflow
**Severity**: Low
**Category**: evm-audit-general
**Location**: `grant()` in Support.sol:170, SupportRenderer._buildSVG():54
**Description**: The `grant()` function accepts a `startAt` parameter with no validation that it is in the past or future. If the owner sets `startAt` to a future timestamp, the `_buildSVG` function will compute `block.timestamp - data.startedAt` which underflows and reverts, breaking `tokenURI()` for that token until the timestamp passes.

Similarly, if `startAt` is very far in the past, `dayNum` could become extremely large, but this is only a display issue.

**Proof of Concept**: Owner calls `grant(alice, 0, 1, uint64(block.timestamp + 30 days))`. Alice's token's `tokenURI()` will revert for 30 days due to underflow at `block.timestamp - data.startedAt`.

**Recommendation**: Validate that `startAt <= block.timestamp` in `grant()`, or handle the case in the renderer:
```solidity
// In grant():
if (startAt > block.timestamp) revert InvalidDuration();

// Or in renderer:
uint256 dayNum = block.timestamp >= data.startedAt
    ? (block.timestamp - data.startedAt) / 1 days + 1
    : 0;
```

---

## [G-14] No `receive()`/`fallback()` function, but contract holds ETH between `support()` and `withdraw()`
**Severity**: Info
**Category**: evm-audit-general
**Location**: Support.sol (entire contract)
**Description**: The contract correctly omits `receive()` and `fallback()` functions, meaning it can only receive ETH via `payable` functions (`support()`). This is a positive security property. However, the `NothingToWithdraw` check at line 241 (`if (balance == 0) revert`) could be affected by selfdestruct force-feeding -- the owner would always be able to withdraw even if no subscriptions were made. This is benign (free ETH for the owner) but worth noting.

**Proof of Concept**: N/A -- informational only.

**Recommendation**: No action required. This is a positive design note.

---

## [G-15] `_lastTier()` reverts on subscriptionId with empty `tierHistory`, but this should be unreachable
**Severity**: Info
**Category**: evm-audit-general
**Location**: `_lastTier()` in Support.sol:331-334
**Description**: `_lastTier()` accesses `periods[periods.length - 1]` without checking that the array is non-empty. If `tierHistory[subscriptionId]` is empty, this reverts with an array out-of-bounds error. This is called from `_resolveSubscription` (line 264) when `subscriptionId != 0`, and from `currentTier` (line 201) and `_applySubscription` (line 314).

In normal operation, `tierHistory` is populated when a subscription is first created (`_applySubscription` at line 313), and `delete tierHistory[subscriptionId]` (line 312) is immediately followed by a `push`. So an empty array should be unreachable for any valid subscriptionId. However, if a subscriptionId were somehow created without a `tierHistory` entry (e.g., through a future code change), `_lastTier` would revert without a clear error message.

**Proof of Concept**: Not reachable under current code. Would require a code modification that creates a subscription without populating tierHistory.

**Recommendation**: Consider adding a descriptive revert:
```solidity
function _lastTier(uint256 subscriptionId) internal view returns (uint8) {
    TierPeriod[] storage periods = tierHistory[subscriptionId];
    require(periods.length > 0, "No tier history");
    return periods[periods.length - 1].tier;
}
```

---

## [G-16] Hook call to non-existent address returns true silently (call to address with no code)
**Severity**: Info
**Category**: evm-audit-general
**Location**: `_notifyHook()` in Support.sol:268-274, `_beforeSubscribe()` in Support.sol:338-346
**Description**: The hook functions check `address(h) == address(0)` before calling, but do not verify `address(h).code.length > 0`. If the owner sets a hook to an EOA or a self-destructed contract, the calls to `beforeSubscribe`, `onSubscribe`, and `onRelease` would behave unpredictably. For `beforeSubscribe` (which is `view` and returns data), calling an address with no code via a high-level Solidity call would revert (since there's no code to return the expected ABI-encoded struct). For `onSubscribe`/`onRelease` (which return nothing), the call would succeed silently as a no-op.

The `address(h) == address(0)` guard handles the "no hook" case, and `setHook` is owner-only, so this requires owner error.

**Proof of Concept**: Owner calls `setHook(someEOA)`. Next `support()` call reverts on `beforeSubscribe` because the EOA has no code to return `Adjustments memory`.

**Recommendation**: Add a code-existence check in `setHook`:
```solidity
function setHook(ISubscriptionHook _hook) external onlyOwner {
    if (address(_hook) != address(0) && address(_hook).code.length == 0) revert InvalidHook();
    hook = _hook;
    emit HookUpdated(address(_hook));
}
```

---

## [G-17] `_changeTier` division in cost supplement calculation may charge slightly less than expected due to rounding
**Severity**: Info
**Category**: evm-audit-general
**Location**: `_changeTier()` in Support.sol:293
**Description**: At line 293, the supplemental cost for upgrading is calculated as:
```solidity
required += _baseCost(uint256(newPrice) * (minExpiry - rawExpiry) / 30 days);
```
The division by `30 days` (2,592,000 seconds) truncates. For example, if `newPrice = 1000` (in 8-decimal USD) and `(minExpiry - rawExpiry) = 1,000,000` seconds, the USD amount is `1000 * 1000000 / 2592000 = 385` (truncated from 385.8). The user pays slightly less than the true pro-rated cost. Over many transactions, this benefits users at the protocol's expense, but the amounts are negligible.

**Proof of Concept**: Arithmetic rounding inherent to integer division. The maximum loss per transaction is less than 1 unit of the price precision.

**Recommendation**: No action required. Standard integer math behavior. Consider rounding up if strictness is desired:
```solidity
uint256 usdSupplement = (uint256(newPrice) * (minExpiry - rawExpiry) + 30 days - 1) / 30 days;
```

---

## [G-18] `tierHistory` array can grow unboundedly via repeated tier changes
**Severity**: Info
**Category**: evm-audit-general
**Location**: `_applySubscription()` in Support.sol:314-315
**Description**: Each tier change pushes a new `TierPeriod` to `tierHistory[subscriptionId]`. There is no limit on the number of tier changes per subscription. Over many tier changes, this array grows, increasing gas costs for `tokenURI()` (which reads the full array in `_attributes()` at SupportRenderer.sol:116) and for `tierPeriods()`. In extreme cases, `tokenURI()` could exceed gas limits.

In practice, each tier change requires payment, so this is self-limiting economically. The array is also reset when a subscription expires and is reactivated (line 312).

**Proof of Concept**: Change tiers 100 times on a single subscription. Each `tokenURI()` call must iterate all 100 tier periods to build attributes, increasing gas cost linearly.

**Recommendation**: Consider capping the number of tier periods stored, or only storing the N most recent periods.
