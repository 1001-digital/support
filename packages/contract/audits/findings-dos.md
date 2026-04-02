# DoS & Griefing Audit Findings

**Scope**: `contracts/` (excluding `mocks/`)
**Checklist**: `evm-audit-dos`
**Date**: 2026-04-02

---

## [DOS-1] Unbounded loop in MaxSlotsHook.onSubscribe iterates all holders
**Severity**: High
**Category**: evm-audit-dos
**Location**: `MaxSlotsHook.onSubscribe()` at `contracts/hooks/MaxSlotsHook.sol:60-67`
**Description**: When the `_tierHolders[tier]` array is full (i.e., `holders.length >= max`), `onSubscribe()` loops through every holder to find an inactive one to evict. The `maxSlots[tier]` value is set by the owner and the holders array grows up to that limit. Each iteration makes two cross-contract calls to `ISupport(support).subscription()` and `ISupport(support).currentTier()` via `_isActiveOnTier()`. If `maxSlots` is set to a large value (e.g., 500+), the gas cost of this loop can exceed the block gas limit on mainnet, or become prohibitively expensive. Because `onSubscribe()` is called within the `support()` transaction (line 150 of `Support.sol`), the entire subscription transaction reverts.

Even on mainnet with a moderate `maxSlots`, consider that every iteration performs two external `STATICCALL` operations plus storage reads in the target contract -- roughly 5,000-10,000 gas per iteration. At 500 slots, the loop alone costs 2.5M-5M gas, which is feasible but tight. On L2s with cheap gas, the owner could set much larger values with no economic deterrent to filling the array.

Note: this is bounded by the owner-set `maxSlots` value, not directly user-growable, which limits the severity somewhat. But if the owner sets a value that is too high and the tier fills up with active subscribers, the loop will always traverse all holders and revert with `TierFull()` after consuming maximum gas.

**Proof of Concept**:
1. Owner sets `maxSlots[0] = 1000`.
2. 1000 users subscribe to tier 0.
3. All 1000 are active.
4. User 1001 calls `support()` for tier 0.
5. `onSubscribe()` iterates all 1000 holders, calling `_isActiveOnTier()` (2 external calls each = 2000 external calls).
6. Transaction runs out of gas or reverts with `TierFull()` after consuming ~10M+ gas.

**Recommendation**: Replace the linear scan with a counter-based approach. Track the count of active holders separately instead of iterating to find inactive slots. Alternatively, cap `maxSlots` to a safe upper bound (e.g., 100) in `setMaxSlots()`. A more gas-efficient design would maintain a free-list of evictable indices:

```solidity
function setMaxSlots(uint8 tier, uint16 max) external onlyOwner {
    require(max <= MAX_SLOTS_CAP, "Too many slots"); // e.g., MAX_SLOTS_CAP = 100
    maxSlots[tier] = max;
    emit MaxSlotsUpdated(tier, max);
}
```

---

## [DOS-2] Unbounded loop in MaxSlotsHook._canSubscribe iterates all holders
**Severity**: Medium
**Category**: evm-audit-dos
**Location**: `MaxSlotsHook._canSubscribe()` at `contracts/hooks/MaxSlotsHook.sol:125-129`
**Description**: `_canSubscribe()` is called from `beforeSubscribe()` (line 37), which is a `view` function invoked during `support()` and `estimate()`. When the tier is full, it iterates all holders with two external calls per iteration (same as DOS-1). This is called even earlier in the `support()` flow (via `_beforeSubscribe` at `Support.sol:128`), meaning the gas is consumed before any state changes.

Additionally, `_canSubscribe()` is called by the public `canSubscribe()` view function (line 43). Off-chain callers (frontends) querying this will get reverts or timeouts for large holder arrays.

**Proof of Concept**: Same as DOS-1. The `_canSubscribe` loop is hit first, during the `beforeSubscribe` call at `Support.sol:128`. If it consumes too much gas, the entire `support()` call reverts before even reaching `onSubscribe`.

**Recommendation**: Same as DOS-1. Use a counter or bitmap to track active vs. inactive holders instead of iterating. Alternatively, the `_canSubscribe` check could be made O(1) by maintaining an `activeCount` variable decremented on `onRelease` and incremented on `onSubscribe`.

---

## [DOS-3] Unbounded loop in MaxSlotsHook.activeTierHolders view function
**Severity**: Low
**Category**: evm-audit-dos
**Location**: `MaxSlotsHook.activeTierHolders()` at `contracts/hooks/MaxSlotsHook.sol:103-115`
**Description**: `activeTierHolders()` iterates the holders array twice -- once to count active holders (line 106-108), once to populate the return array (line 110-113). Each iteration calls `_isActiveOnTier()` which makes two cross-contract calls. For large holder arrays, this view function will revert due to gas limits (even `eth_call` has a gas cap, typically 30M-50M on RPC providers).

This is a view function only, so it cannot block state-changing operations. However, it can make the contract unusable for frontends and indexers that depend on this data.

**Proof of Concept**:
1. A tier has 500+ holders.
2. Frontend calls `activeTierHolders(tier)`.
3. The call exceeds the RPC provider's gas limit and reverts.

**Recommendation**: Add pagination parameters or remove the function in favor of off-chain indexing via events. For example:

```solidity
function activeTierHolders(uint8 tier, uint256 offset, uint256 limit) external view returns (address[] memory) {
    // paginated implementation
}
```

---

## [DOS-4] Malicious or reverting hook can permanently DoS all subscriptions
**Severity**: High
**Category**: evm-audit-dos
**Location**: `Support._beforeSubscribe()` at `contracts/Support.sol:338-346` and `Support._notifyHook()` at `contracts/Support.sol:268-274`
**Description**: The hook contract is called in two places during `support()`: first via `_beforeSubscribe()` (line 128) which calls `h.beforeSubscribe()`, and then via `_notifyHook()` (line 150) which calls `h.onRelease()` and `h.onSubscribe()`. None of these calls are wrapped in `try/catch`. If the hook reverts for any reason, the entire `support()` transaction reverts.

The hook is set by the owner via `setHook()`, so this is an owner-trust issue. However:
- A previously benign hook contract could be upgraded (if it uses a proxy pattern) to always revert.
- A hook with a bug could revert under specific conditions, blocking all subscriptions.
- A hook could run out of gas due to internal complexity, causing all subscriptions to fail.

The same risk applies to `grant()` (line 175) and to NFT transfers in `WithSupportTokens._update()` (lines 79-83).

**Proof of Concept**:
1. Owner sets a hook that has a bug causing `onSubscribe()` to revert for certain addresses.
2. Any user whose subscription triggers that code path cannot subscribe.
3. If `beforeSubscribe()` reverts universally, no subscriptions can be created at all.

The mitigation is that the owner can call `setHook(address(0))` to disable the hook. However, there is a window of DoS between when the hook starts reverting and when the owner notices and removes it.

**Recommendation**: Wrap hook calls in `try/catch` to make them non-blocking, or at minimum wrap `onSubscribe` and `onRelease` (the post-state-change notifications) so that a hook failure does not prevent subscription creation. The `beforeSubscribe` call is harder to wrap since its return value is needed for pricing.

```solidity
function _notifyHook(ISubscriptionHook h, uint8 previousTier, uint8 tier, address recipient) internal {
    if (address(h) == address(0)) return;
    if (previousTier != NO_TIER && previousTier != tier) {
        try h.onRelease(previousTier, recipient) {} catch {}
    }
    try h.onSubscribe(tier, recipient) {} catch {}
}
```

Note: silencing hook reverts changes the trust model. If hooks are meant to enforce invariants (like MaxSlotsHook enforcing capacity), swallowing errors would break that. The design decision depends on whether hooks are advisory or authoritative. Document the chosen model clearly.

---

## [DOS-5] ETH refund to msg.sender can be blocked by a reverting receiver
**Severity**: Medium
**Category**: evm-audit-dos
**Location**: `Support.support()` at `contracts/Support.sol:154-158`
**Description**: When a user overpays, the excess ETH is refunded via `msg.sender.call{value: excess}("")`. If `msg.sender` is a contract that reverts on receiving ETH (no `receive()` function, or a `receive()` that reverts), the entire `support()` transaction reverts due to the `if (!sent) revert TransferFailed()` check.

This means a contract that intentionally reverts on ETH receipt cannot subscribe via `support()` even if it sends the exact amount, because any rounding difference from the price feed could produce a tiny excess. More importantly, a third party calling `support(recipient, ...)` from a contract without a `receive()` function will always fail if there is any excess.

**Proof of Concept**:
1. A multisig or DAO contract (without `receive()`) calls `support(someAddress, 0, 1)` with slightly more ETH than required.
2. `excess > 0`, so the contract tries to refund via `.call{value: excess}("")`.
3. The multisig has no `receive()` function, so the call fails.
4. `support()` reverts with `TransferFailed`.

**Recommendation**: Use the pull-payment pattern for refunds. Instead of pushing excess ETH back immediately, store it as a claimable balance:

```solidity
mapping(address => uint256) public pendingRefunds;

// In support():
if (excess > 0) {
    pendingRefunds[msg.sender] += excess;
}

function claimRefund() external {
    uint256 amount = pendingRefunds[msg.sender];
    pendingRefunds[msg.sender] = 0;
    (bool sent, ) = msg.sender.call{value: amount}("");
    if (!sent) revert TransferFailed();
}
```

Alternatively, if the caller is expected to calculate the exact payment, simply accept the overpayment without refunding (less user-friendly).

---

## [DOS-6] Returndata bombing via hook external calls
**Severity**: Low
**Category**: evm-audit-dos
**Location**: `Support._beforeSubscribe()` at `contracts/Support.sol:345`, `Support._notifyHook()` at `contracts/Support.sol:271-273`
**Description**: Hook calls are made via Solidity's high-level call syntax (e.g., `h.beforeSubscribe(...)`, `h.onSubscribe(...)`). The EVM copies all return data into the caller's memory. A malicious hook could return a very large payload, causing the caller to consume excessive gas for memory expansion. Since the hook is set by the owner, this requires owner collusion or a compromised/upgraded hook contract.

For `beforeSubscribe`, the return type is `Adjustments memory` which is a fixed-size struct, so Solidity will only ABI-decode the expected amount. However, the EVM still copies the full returndata into memory before decoding. A hook returning 1MB of data would cost ~3M gas in memory expansion alone.

For `onSubscribe` and `onRelease`, these return `void`, but the EVM still copies any returned data.

**Proof of Concept**:
1. Owner (or compromised owner) sets a hook that returns 100KB of data from `onSubscribe()`.
2. Every subscription call pays an extra ~300K gas for memory expansion.
3. This is a gas griefing attack, not a full DoS, since the transaction still succeeds.

**Recommendation**: This is mitigated by the fact that the hook is owner-set. For defense in depth, consider using inline assembly for hook calls to cap the return data size, or use `try/catch` which avoids copying return data on success for void functions. Given the trust model (owner sets hooks), this is informational.

---

## [DOS-7] tierHistory array grows unboundedly with tier changes
**Severity**: Low
**Category**: evm-audit-dos
**Location**: `Support._applySubscription()` at `contracts/Support.sol:314-315`
**Description**: Each time an active subscriber changes tiers, a new `TierPeriod` is pushed to `tierHistory[subscriptionId]` (line 315). There is no cap on how many tier changes can occur. A subscriber (or the owner via `grant()`) could repeatedly change tiers, growing the array.

However, in practice this is self-limiting:
- Each tier change via `support()` requires payment (the new tier's cost for at least 30 days on upgrade).
- The owner can change tiers via `grant()` for free, but the owner is trusted.
- When a subscription expires and is reactivated, `tierHistory` is deleted and reset (line 312-313).

The primary impact is on `tokenURI()` which passes `tierHistory[tokenId]` to the renderer, and the renderer loops over it in `_attributes()` (SupportRenderer.sol:116-124). A very large `tierHistory` could make `tokenURI()` too expensive to call.

**Proof of Concept**:
1. Owner repeatedly calls `grant(address, tier0, 0, 0)` then `grant(address, tier1, 0, 0)` alternating tiers.
2. Each call appends to `tierHistory`.
3. After hundreds of entries, `tokenURI()` becomes too gas-expensive to call.

**Recommendation**: Cap the number of tier periods per subscription, or paginate the renderer's attribute output. Since `tokenURI` is a view function, the impact is limited to off-chain reads. A simple cap:

```solidity
uint256 internal constant MAX_TIER_PERIODS = 50;

// In _applySubscription:
if (tier != _lastTier(subscriptionId)) {
    require(tierHistory[subscriptionId].length < MAX_TIER_PERIODS, "Too many tier changes");
    tierHistory[subscriptionId].push(TierPeriod(tier, uint64(block.timestamp)));
}
```

---

## [DOS-8] SupportRenderer._attributes() loops over unbounded tierPeriods array
**Severity**: Low
**Category**: evm-audit-dos
**Location**: `SupportRenderer._attributes()` at `contracts/renderers/SupportRenderer.sol:116-124`
**Description**: The `_attributes()` function iterates over `data.tierPeriods` with no upper bound. Each iteration performs multiple `string.concat` and `Strings.toString` operations, which are gas-intensive due to memory allocation. This is called from `tokenURI()`, which is a view function.

This is the downstream consequence of DOS-7. If a subscription has many tier periods, `tokenURI()` will revert due to gas limits on RPC calls.

**Proof of Concept**: Same as DOS-7. Once `tierHistory` has hundreds of entries, calling `tokenURI()` via `eth_call` exceeds typical RPC gas limits (30M-50M gas).

**Recommendation**: Limit the number of tier periods rendered (e.g., show only the last N), or cap tier period growth as recommended in DOS-7.

```solidity
function _attributes(TokenData calldata data) internal pure returns (string memory) {
    // ... base attributes ...
    uint256 maxPeriods = data.tierPeriods.length > 20 ? 20 : data.tierPeriods.length;
    for (uint256 i; i < maxPeriods; ++i) {
        // ...
    }
    return attrs;
}
```

---

## [DOS-9] Owner withdraw() can be blocked by a reverting owner address
**Severity**: Low
**Category**: evm-audit-dos
**Location**: `Support.withdraw()` at `contracts/Support.sol:239-245`
**Description**: The `withdraw()` function sends all ETH to `owner()` via `.call{value: balance}("")`. If ownership is transferred to a contract that cannot receive ETH, all collected funds become permanently locked. The contract uses `Ownable2Step`, which requires the new owner to call `acceptOwnership()`, so the new owner must be able to execute transactions. However, the new owner contract might be able to call `acceptOwnership()` but have a reverting `receive()` function.

**Proof of Concept**:
1. Owner transfers ownership to a smart contract that can call `acceptOwnership()` but has no `receive()` function.
2. New owner accepts ownership.
3. `withdraw()` sends ETH to the new owner, which reverts.
4. Funds are locked until ownership is transferred again (which the new owner can still do).

**Recommendation**: This is largely mitigated by `Ownable2Step` (the new owner must actively accept). Additionally, `renounceOwnership()` is disabled (line 103-105). The owner can always transfer ownership to a working address. No code change required, but consider documenting this risk for operators.

---

## [DOS-10] Hook calls during NFT transfers can block token transfers
**Severity**: Medium
**Category**: evm-audit-dos
**Location**: `WithSupportTokens._update()` at `contracts/extensions/WithSupportTokens.sol:79-83`
**Description**: When an active subscription NFT is transferred, `_update()` calls `h.onRelease(tier, from)` and `h.onSubscribe(tier, to)` on the hook contract. These calls are not wrapped in `try/catch`. If the hook reverts (e.g., `MaxSlotsHook.onSubscribe()` reverts with `TierFull()` because the tier is full for the recipient), the NFT transfer is blocked.

This means:
- If a tier has max slots and all are filled, transferring an active subscription NFT to a new address that is not already a holder will revert (even though the transfer should logically free up a slot from the sender).
- The order of operations matters: `onRelease` is called before `onSubscribe`. In `MaxSlotsHook`, `onRelease` removes the sender from the holders array, so `onSubscribe` for the recipient should find a free slot. However, if the hook has a bug or different logic, this could fail.
- Any hook that reverts on `onSubscribe` for any reason blocks all NFT transfers of active subscriptions.

**Proof of Concept**:
1. Tier 0 has `maxSlots = 5` with 5 active holders.
2. Holder A tries to transfer their NFT to address B (not a current holder).
3. `_update()` calls `h.onRelease(0, A)` -- succeeds, removes A, now 4 holders.
4. `_update()` calls `h.onSubscribe(0, B)` -- succeeds, adds B, now 5 holders.
5. This specific case works. But if the hook has rate limiting or other logic, transfers could be blocked.

More concretely, if the hook is a custom contract that reverts on `onSubscribe` for non-whitelisted addresses, NFT transfers to those addresses are permanently blocked.

**Recommendation**: Consider wrapping hook calls in `_update()` with `try/catch`, or provide a way to transfer NFTs without hook interaction (e.g., an emergency transfer function that skips hooks). At minimum, document that hook implementations must handle transfer scenarios gracefully.

---

## Checklist Items With No Issues Found

**Insufficient gas forwarding (SWC-126)**: No fixed-gas `.call{gas: X}()` patterns found. All external calls use default gas forwarding.

**Try/catch always fails with insufficient gas**: No `try/catch` blocks are used in the codebase.

**External calls inside loops**: The loops in `MaxSlotsHook` do make external calls inside loops (covered in DOS-1, DOS-2, DOS-3), but there are no token transfers inside loops.

**Token transfer to blocklisted address**: No ERC-20 token transfers in any of the contracts.

**Zero-amount transfer reverts**: No ERC-20 token transfers.

**Block stuffing to prevent time-sensitive actions**: The only time-sensitive check is `afterSaleStart` in `support()`, which is a one-time gate, not a deadline. No auction or liquidation mechanics exist.

**Timelock-based griefing**: No timelock mechanisms.

**Front-running liquidation griefing**: No liquidation mechanics.

**Account abstraction DoS via free paymaster**: No paymaster or ERC-4337 integration.

**Pause-related DoS**: No pause mechanism exists in these contracts.

**Oracle DoS (Chainlink)**: The contracts use `HasPriceFeed` with a Chainlink `AggregatorV3Interface` for USD-to-ETH conversion. The `_usdToEth()` call is inherited and not visible in the audited source. If the price feed call is not wrapped in `try/catch`, a Chainlink feed outage would DoS all paid subscriptions. However, since the inherited contract is out of scope, this is noted but not scored.

**balanceOf() reverting causes DoS**: No `balanceOf()` calls on external tokens.

**L2 array-filling attacks**: Covered under DOS-1 and DOS-2. On L2s with cheap gas, the `MaxSlotsHook` holder arrays are more economically viable to fill, but the arrays are bounded by `maxSlots` (owner-set), not user-growable without limit.
