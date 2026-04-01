# DoS & Griefing Audit Findings

Audit of the Support contract system against the `evm-audit-dos` checklist.

Audited contracts:
- `contracts/Support.sol`
- `contracts/SupportToken.sol`
- `contracts/extensions/WithSupportTokens.sol`
- `contracts/hooks/MaxSlotsHook.sol`
- `contracts/hooks/DiscountHook.sol`
- `contracts/interfaces/ISubscriptionHook.sol`

---

## [DOS-1] Unbounded loop in MaxSlotsHook.onSubscribe blocks new subscriptions
**Severity**: High
**Category**: evm-audit-dos
**Location**: `MaxSlotsHook.onSubscribe()` at `hooks/MaxSlotsHook.sol:65`
**Description**: When the `_tierHolders[tier]` array is at capacity (length == maxSlots), `onSubscribe()` iterates the entire array to find an expired holder to evict. Each iteration makes two cross-contract calls to the Support contract (`activeTokenOf` and `currentTier` via `_isActiveOnTier`). If `maxSlots` is set to a high value (e.g., 500+), the gas cost grows linearly and can exceed the block gas limit. Since `onSubscribe()` is called within the `support()` transaction (line 150 of Support.sol via `_notifyHook`), this makes all new subscriptions to that tier revert, permanently DoS-ing the tier once the array is full of active holders.
**Proof of Concept**:
1. Owner sets `maxSlots[0] = 1000`.
2. 1000 users subscribe to tier 0. The `_tierHolders[0]` array reaches length 1000.
3. User 1001 tries to subscribe. `onSubscribe()` iterates all 1000 entries, each calling `_isActiveOnTier()` (2 external calls per iteration = 2000 external calls).
4. The transaction exceeds the block gas limit and reverts. No further subscriptions to tier 0 are possible, even if some holders have expired, because the check itself cannot complete.
**Recommendation**: Replace the linear scan with an explicit free-slot tracking mechanism. Maintain a separate counter of active holders or use a linked list / bitmap to track available slots in O(1). Alternatively, cap `maxSlots` to a small value (e.g., 50) and document the gas constraint.

---

## [DOS-2] Unbounded loop in MaxSlotsHook._canSubscribe blocks subscriptions and view calls
**Severity**: High
**Category**: evm-audit-dos
**Location**: `MaxSlotsHook._canSubscribe()` at `hooks/MaxSlotsHook.sol:132`
**Description**: The `_canSubscribe()` function is called from `beforeSubscribe()` (line 42), which runs inside the `support()` transaction via `_beforeSubscribe()` in Support.sol (line 128). When the tier is full, `_canSubscribe()` iterates the entire `_tierHolders[tier]` array with cross-contract calls to `_isActiveOnTier()`. This is a `view` call path, but it is invoked within the state-changing `support()` function, so it consumes real gas. The same array-length problem described in DOS-1 applies here, and in fact this loop runs before `onSubscribe()`, meaning the DoS triggers even earlier. Additionally, the `cost()` and `estimate()` public view functions (Support.sol lines 181-198) also call `_beforeSubscribe()` with hook, so even off-chain cost estimation calls can run out of gas.
**Proof of Concept**:
1. Same setup as DOS-1 with a large `maxSlots` value and a full tier.
2. Calling `support()`, `cost()`, or `estimate()` triggers `_canSubscribe()` which iterates the full array.
3. If all holders are active, every entry is checked. With 1000 holders, this means 2000 external calls just in `_canSubscribe`, plus another 2000 in `onSubscribe` -- roughly 4000 external calls total.
**Recommendation**: Same as DOS-1. Use O(1) slot tracking instead of linear scans. Alternatively, maintain a `uint16 activeCount` per tier that is incremented/decremented in `onSubscribe`/`onRelease`, and compare directly against `maxSlots`.

---

## [DOS-3] Unbounded loop in MaxSlotsHook.activeTierHolders iterates full array twice
**Severity**: Low
**Category**: evm-audit-dos
**Location**: `MaxSlotsHook.activeTierHolders()` at `hooks/MaxSlotsHook.sol:109-121`
**Description**: The `activeTierHolders()` view function iterates the `_tierHolders[tier]` array twice -- once to count active holders and once to populate the return array. Each iteration calls `_isActiveOnTier()` which makes 2 cross-contract calls. For a large array, this can exceed the RPC node's gas limit for `eth_call`, making the function uncallable. While this is a view function with no on-chain impact, it can break frontend integrations and off-chain tooling that depend on this data.
**Proof of Concept**:
1. Set `maxSlots[0] = 1000` and fill the tier.
2. Call `activeTierHolders(0)` -- this makes approximately 4000 external calls (2 passes x 1000 entries x 2 calls each).
3. The call runs out of gas on the RPC node's `eth_call` gas limit (commonly 30M).
**Recommendation**: Add pagination parameters (offset, limit) or maintain an active-holders counter to avoid the double pass. Consider emitting events for holder changes instead.

---

## [DOS-4] External hook calls can permanently block subscriptions
**Severity**: High
**Category**: evm-audit-dos
**Location**: `Support._beforeSubscribe()` at `Support.sol:363` and `Support._notifyHook()` at `Support.sol:273-279`
**Description**: The `support()` function makes multiple external calls to the hook contract: `beforeSubscribe()` (via `_beforeSubscribe` at line 128), `onSubscribe()` and `onRelease()` (via `_notifyHook` at line 150). These are direct calls without `try/catch` -- if the hook contract reverts for any reason (bug, self-destruct, out of gas, malicious logic), the entire `support()` transaction reverts. Since the hook is set by the owner, a misconfigured or buggy hook permanently DoS-es all subscriptions. The `grant()` function (line 175) also calls `_notifyHook`, so even owner grants are blocked.
**Proof of Concept**:
1. Owner deploys a hook contract and sets it via `setHook()`.
2. The hook contract has a bug that causes `onSubscribe()` to revert.
3. All calls to `support()` and `grant()` revert.
4. Until the owner calls `setHook(address(0))` or sets a new hook, subscriptions are frozen.
**Recommendation**: Wrap hook calls in `try/catch` blocks so that a failing hook does not block core subscription functionality. Emit an event when a hook call fails so the owner is alerted. Example:
```solidity
function _notifyHook(ISubscriptionHook h, uint8 previousTier, uint8 tier, address recipient) internal {
    if (address(h) == address(0)) return;
    if (previousTier != type(uint8).max && previousTier != tier) {
        try h.onRelease(previousTier, recipient) {} catch {}
    }
    try h.onSubscribe(tier, recipient) {} catch {}
}
```
Note: This changes the trust model -- the owner must decide whether hook enforcement is critical (current behavior) or best-effort. If enforcement is required, the current design is intentional but the owner must be aware of the DoS risk.

---

## [DOS-5] Excess ETH refund to reverting contract blocks subscriptions
**Severity**: Medium
**Category**: evm-audit-dos
**Location**: `Support.support()` at `Support.sol:155-158`
**Description**: When a subscriber overpays, the excess ETH is refunded via `msg.sender.call{value: excess}("")`. If `msg.sender` is a contract with a reverting `receive()` or `fallback()` function, and it sends more ETH than required, the refund fails and the entire `support()` call reverts. This only affects the specific caller (not other users), but it means a contract-based subscriber that deliberately or accidentally overpays cannot subscribe. More critically, if a third party is calling `support()` on behalf of a recipient (which the contract allows), a malicious contract caller could grief the recipient by ensuring the refund always reverts.
**Proof of Concept**:
1. Deploy a contract that calls `support{value: excess}(recipient, tier, duration)` where `excess > required`, and has no `receive()` function.
2. The `support()` function computes `excess > 0`, calls `msg.sender.call{value: excess}("")`, which reverts.
3. The entire transaction reverts with `TransferFailed`.
**Recommendation**: Use the pull-payment pattern for refunds. Store the excess amount in a mapping and let the caller withdraw it later. Alternatively, require exact payment and remove the refund logic:
```solidity
if (msg.value != required) revert IncorrectPayment();
```

---

## [DOS-6] Returndata bombing on excess ETH refund call
**Severity**: Low
**Category**: evm-audit-dos
**Location**: `Support.support()` at `Support.sol:156`
**Description**: The refund call `msg.sender.call{value: excess}("")` does not cap the return data size. A malicious `msg.sender` contract can return a very large payload (e.g., megabytes), and the EVM will copy all of it into the caller's memory, consuming gas proportional to the return data size. Since this is `msg.sender` (the caller themselves), the griefing is self-inflicted in most cases. However, if a contract calls `support()` on behalf of a recipient, the gas overhead from returndata copying could cause unexpected out-of-gas reverts.
**Proof of Concept**:
1. Deploy a contract that calls `support()` with excess ETH.
2. The contract's `receive()` function returns a large byte array (e.g., 100KB).
3. The EVM copies 100KB into memory, consuming ~3200 gas per 32 bytes = ~100K extra gas.
4. If the transaction was submitted with tight gas limits, it reverts.
**Recommendation**: Use inline assembly to cap the return data:
```solidity
assembly {
    let success := call(gas(), caller(), excess, 0, 0, 0, 0)
    if iszero(success) {
        // handle failure
    }
}
```
Or switch to a pull-payment pattern as recommended in DOS-5.

---

## [DOS-7] Unbounded token balance loops in WithSupportTokens can DoS transfers
**Severity**: Medium
**Category**: evm-audit-dos
**Location**: `WithSupportTokens._transferActiveToken()` at `extensions/WithSupportTokens.sol:108`, `_receiveActiveToken()` at line 128, `_activeTokenOf()` at line 155, `_hasActiveTierToken()` at line 167
**Description**: Four functions in `WithSupportTokens` iterate over a user's entire ERC-721 token balance using `balanceOf()` and `tokenOfOwnerByIndex()`. If a single address accumulates a large number of tokens (e.g., by receiving many subscriptions as gifts or buying them on secondary markets), these loops become expensive. The `_update()` function (called on every ERC-721 transfer) invokes `_transferActiveToken`, `_receiveActiveToken`, and `_hasActiveTierToken` -- potentially iterating the sender's and receiver's full balance up to 4 times. This can make transfers prohibitively expensive or impossible for addresses with many tokens.
**Proof of Concept**:
1. An address accumulates 500 subscription tokens (via `support()` calls from third parties or secondary market purchases).
2. That address tries to transfer one token. `_update()` calls `_transferActiveToken()` (iterates up to 500), `_receiveActiveToken()` on receiver (iterates receiver's balance), and `_hasActiveTierToken()` on both sender and receiver (up to 500 each).
3. With 4 loops of up to 500 iterations each, the gas cost can exceed practical limits.
**Recommendation**: Maintain a dedicated "active token" pointer that is updated in O(1) on subscribe/expire, rather than scanning the full balance. Alternatively, limit the number of tokens per address (though this is architecturally limiting for ERC-721).

---

## [DOS-8] Returndata bombing on owner withdrawal call
**Severity**: Low
**Category**: evm-audit-dos
**Location**: `Support.withdraw()` at `Support.sol:247`
**Description**: The `withdraw()` function sends ETH to `owner()` via `.call{value: balance}("")`. If the owner is a smart contract (e.g., a multisig or DAO), the return data is not capped. A malicious or buggy owner contract could return excessive data, inflating gas costs. Since only the owner can call `withdraw()` and the recipient is the owner themselves, this is self-inflicted. However, if ownership is transferred to a contract that unexpectedly returns large data, withdrawals could fail due to out-of-gas.
**Proof of Concept**:
1. Owner transfers ownership to a contract with a `receive()` function that returns large data.
2. Calling `withdraw()` copies excessive return data, consuming unexpected gas.
**Recommendation**: Use assembly to discard return data on the withdrawal call, same pattern as DOS-6.

---

## [DOS-9] Hook external calls inside ERC-721 transfer path can block token transfers
**Severity**: Medium
**Category**: evm-audit-dos
**Location**: `WithSupportTokens._update()` at `extensions/WithSupportTokens.sol:88-95`
**Description**: When an active subscription token is transferred, `_update()` calls `hook.onRelease()` and `hook.onSubscribe()` (lines 91-95). These are external calls to the hook contract. If the hook reverts (e.g., `MaxSlotsHook.onSubscribe()` reverts with `TierFull` because the recipient's tier is full), the entire ERC-721 transfer reverts. This means a buggy or restrictive hook can prevent token transfers, which is a core ERC-721 operation.
**Proof of Concept**:
1. MaxSlotsHook is set with `maxSlots[0] = 10`, and tier 0 is full.
2. Alice holds an active tier 0 token and tries to transfer it to Bob.
3. `_update()` calls `hook.onRelease(0, alice)` (succeeds, frees a slot), then `hook.onSubscribe(0, bob)`.
4. But `onSubscribe` first checks `_canSubscribe()` -- wait, actually `onSubscribe` in `_update` is called directly without `beforeSubscribe` gating. If the tier is at capacity, `onSubscribe()` reverts with `TierFull()` at line 74.
5. The transfer reverts.
**Recommendation**: Wrap hook calls in `_update()` in `try/catch` so that hook failures do not block token transfers. Alternatively, ensure `onSubscribe` in MaxSlotsHook handles the transfer case gracefully (the releasing of the old holder should free a slot for the new holder, but the `onRelease` and `onSubscribe` are called separately with no atomicity guarantee that the slot freed by `onRelease` is still free when `onSubscribe` runs).

---

## [DOS-10] L2 deployment makes MaxSlotsHook array-filling attacks economically viable
**Severity**: Medium
**Category**: evm-audit-dos
**Location**: `MaxSlotsHook._tierHolders` at `hooks/MaxSlotsHook.sol:25`
**Description**: If these contracts are deployed on an L2 (Arbitrum, Base, Optimism, etc.), the low gas costs make it cheap for an attacker to fill the `_tierHolders` arrays. On mainnet, subscribing hundreds of times costs significant ETH in gas. On L2s, an attacker could create hundreds of subscriptions across sybil addresses at minimal cost, filling tier slots and triggering the gas-heavy linear scans described in DOS-1 and DOS-2. Even if `tierPrices` make subscriptions expensive, the attacker could target a free tier (price = 0) if one exists.
**Proof of Concept**:
1. Contract is deployed on Base with `tierPrices[0] = 0` (free tier) and `maxSlots[0] = 500`.
2. Attacker calls `support()` 500 times from different addresses with 0 ETH (gas cost ~$0.01 per tx on Base = ~$5 total).
3. All 500 slots are filled. Legitimate users are blocked from tier 0.
4. Even after slots expire, the linear scan in `_canSubscribe` and `onSubscribe` makes new subscriptions gas-heavy.
**Recommendation**: Do not allow free tiers when using MaxSlotsHook, or add a minimum subscription cost. Cap `maxSlots` to a value where the linear scan cost is acceptable. Consider adding a deposit mechanism or rate limiting.

---

## [DOS-11] Hook calls with cross-contract reads inside loops create gas amplification
**Severity**: Medium
**Category**: evm-audit-dos
**Location**: `MaxSlotsHook._isActiveOnTier()` at `hooks/MaxSlotsHook.sol:138-143`
**Description**: The `_isActiveOnTier()` helper makes two external calls to the Support contract per invocation: `activeTokenOf()` and `currentTier()`. When called from within the loops in `_canSubscribe()`, `onSubscribe()`, and `activeTierHolders()`, this creates a gas amplification effect. Each loop iteration costs roughly 5000-10000 gas for the two external STATICCALL operations (base cost + memory), multiplied by the array length. Notably, `activeTokenOf()` in WithSupportTokens (line 148) itself contains an unbounded loop over the user's token balance, creating a nested loop scenario: the outer loop iterates tier holders, and for each holder, the inner loop may iterate their entire token balance.
**Proof of Concept**:
1. MaxSlotsHook tier 0 has 100 holders, each owning 50 tokens.
2. `_canSubscribe()` iterates 100 holders. For each, `_isActiveOnTier()` calls `activeTokenOf()`.
3. `activeTokenOf()` in WithSupportTokens iterates up to 50 tokens per holder (if cached pointer is stale).
4. Worst case: 100 * 50 = 5000 inner iterations plus 100 * 2 external calls = extremely high gas.
**Recommendation**: Ensure `activeTokenOf()` is O(1) by maintaining the `activeToken` mapping eagerly (not lazily). The current lazy scan in `_activeTokenOf` (WithSupportTokens line 148-163) should be replaced with a maintained pointer that is always up-to-date.
