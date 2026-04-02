# ERC-721 Security Audit Findings

**Scope**: ERC-721 implementation in `WithSupportTokens.sol`, `OnePerWallet.sol`, and related contracts
**Checklist**: `evm-audit-erc721`
**Date**: 2026-04-02

---

## Checklist Walkthrough

### Dual Standard Tokens (ERC721 + ERC1155)
No issues found. The contract implements only ERC721 (via OpenZeppelin) and does not implement ERC1155. `supportsInterface` adds ERC-4906 (`0x49064906`) on top of the standard ERC721 interface. No dual-standard ambiguity.

### Legacy & Wrapped NFTs
Not applicable. This contract is the NFT itself, not a protocol consuming external NFTs.

### Multiple Collections on One Contract
Not applicable. The contract hosts a single collection. `setApprovalForAll` and `totalSupply()` apply to one collection only.

### Token ID Quirks
No issues found. Token IDs are sequential starting from 1 (`++_subscriptionIdCounter` in `_applySubscription` at `Support.sol:305`). No large or encoded token IDs, no skipped IDs.

### Self-Destructing / Auto-Burning NFTs
Not applicable. Tokens are never burned by this contract (no burn path exists in `_onNewSubscription`, `_update`, or any other function).

### Upgradeable and Pausable NFTs
Not applicable. The contracts are not upgradeable (no proxy pattern) and not pausable. `renounceOwnership()` reverts unconditionally (`Support.sol:103`), which is a good safety measure.

### NFT Permit (ERC-4494)
Not applicable. No permit mechanism is implemented.

### Airdrops and Breeding
Not applicable. The contract does not hold external NFTs.

### Fractionalized NFTs
Not applicable. No fractionalization mechanism exists.

### Constructor Minting Without Events
No issues found. No minting occurs in the constructor. Tokens are minted via `_mint()` in `_onNewSubscription()` (`WithSupportTokens.sol:92`), which emits standard `Transfer` events.

### ERC721 `transferFrom` vs `safeTransferFrom`
See finding NFT-1 below regarding `_mint` vs `_safeMint`.

### `from` parameter in `transferFrom`
Not applicable. The contract does not expose a custom `transferFrom` with a user-supplied `from`. Standard ERC721 `transferFrom` uses `_update` with `auth = msg.sender` for authorization.

---

## Findings

## [NFT-1] `_mint` used instead of `_safeMint` -- tokens can be lost to non-receiver contracts
**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `_onNewSubscription()` at `WithSupportTokens.sol:92`
**Description**: When a new subscription is created, the token is minted via `_mint(recipient, tokenId)` rather than `_safeMint(recipient, tokenId)`. The `_mint` function does not invoke `onERC721Received` on the recipient. If the recipient is a contract that does not implement `IERC721Receiver`, the token will be minted but permanently inaccessible (the contract cannot transfer it out).

In this system, subscriptions are typically created by calling `support(recipient, tier, duration)` where `recipient` can be any address including a contract. A third party could subscribe a contract address that cannot handle ERC721 tokens.

**Proof of Concept**:
1. Deploy a contract `Vault` that does not implement `IERC721Receiver`.
2. Call `support(address(Vault), 0, 1)` with sufficient ETH.
3. `_applySubscription` calls `_onNewSubscription`, which calls `_mint(Vault, tokenId)`.
4. The mint succeeds, but the token is now stuck -- `Vault` has no way to transfer it.

**Recommendation**: Replace `_mint` with `_safeMint`:
```solidity
function _onNewSubscription(address recipient, uint256 tokenId) internal override {
    _safeMint(recipient, tokenId);
}
```
Note: This introduces a reentrancy vector via `onERC721Received` (see NFT-2). Evaluate whether the reentrancy risk or the stuck-token risk is more acceptable for your use case. Given the one-per-wallet constraint and the fact that `_applySubscription` writes state before `_onNewSubscription` is called, the reentrancy surface is limited but should still be analyzed.

---

## [NFT-2] Reentrancy via `_mint` callback if upgraded to `_safeMint`
**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `_onNewSubscription()` at `WithSupportTokens.sol:92`, called from `_applySubscription()` at `Support.sol:306`
**Description**: If `_mint` is changed to `_safeMint` (as recommended in NFT-1), the `onERC721Received` callback on the recipient would execute before the `support()` function completes. At the point `_onNewSubscription` is called (`Support.sol:306`), `_subscriptionIdCounter` is incremented and `_onNewSubscription` is called, but `subscription[recipient]`, `expiresAt[subId]`, and `tierHistory[subId]` are set afterwards at lines 309-319. The hook notification (`_notifyHook`) and event emission also happen after.

The current code uses `_mint` (no callback), so this is not currently exploitable. This is a latent concern if the code is modified in the future.

**Proof of Concept**: Not currently exploitable. If `_safeMint` were used:
1. Attacker deploys a contract implementing `onERC721Received` that calls `support()` again.
2. On first `support()` call, `_safeMint` triggers the callback.
3. Inside the callback, the attacker's `subscription[attacker]` is still 0, `expiresAt` is still 0.
4. The OnePerWallet check would prevent a second mint (balance already 1 after `_update`), so the re-entrant `support()` would not create a duplicate token. However, the subscription mapping state would be inconsistent during the callback.

**Recommendation**: If switching to `_safeMint`, consider applying OpenZeppelin's `ReentrancyGuard` to the `support()` and `grant()` functions, or ensure all state writes complete before `_onNewSubscription` is invoked. Alternatively, restructure `_applySubscription` so that subscription state is fully written before the mint call.

---

## [NFT-3] Transfer does not clear previous `subscription` mapping for the receiver if they had an expired subscription
**Severity**: Medium
**Category**: evm-audit-erc721
**Location**: `_update()` at `WithSupportTokens.sol:66-87`
**Description**: When a token is transferred to address `to`, the `_update` override sets `subscription[to] = tokenId` unconditionally (line 76). However, if `to` previously held a different subscription (now expired and their token was burned or transferred away), the old subscription ID is silently overwritten. This is actually the correct behavior for tracking the current token.

The real issue is more subtle: when `from` transfers their token to `to`, `subscription[from]` is set to 0 (line 75). If `from` later calls `support()` to re-subscribe, `_resolveSubscription` finds `subscription[from] == 0`, so `_applySubscription` creates a brand new subscription ID and mints a new token. This is the intended design.

However, the `subscription` mapping for the original `to` address now points to the transferred token. If `to` later lets the subscription expire and someone calls `support(to, ...)`, `_resolveSubscription` will return the old (expired) subscription ID. `_applySubscription` will then reuse this subscription ID but NOT mint a new token (because `subscriptionId != 0`). The token still exists and is owned by `to` (it was transferred to them), so this actually works correctly -- the subscription is reactivated on the existing token.

After detailed analysis, this flow is consistent. No issue.

**Severity**: Reclassified to **Info**
**Recommendation**: No action required. The subscription-to-token mapping is 1:1 and maintained correctly through transfers.

---

## [NFT-4] Token transfer to an address that already holds an expired token from a previous subscription is blocked by OnePerWallet
**Severity**: Medium
**Category**: evm-audit-erc721
**Location**: `_update()` at `OnePerWallet.sol:29-45`, `WithSupportTokens.sol:66-87`
**Description**: The `OnePerWallet` extension enforces that no address holds more than one token (`balanceOf(to) > 1` check at `OnePerWallet.sol:39`). Tokens in this system are never burned -- once minted, they persist even after the subscription expires. This means:

1. Alice subscribes, receives token #1.
2. Alice's subscription expires. She still holds token #1.
3. Bob wants to transfer his active token #2 to Alice.
4. The transfer reverts with `OneTokenPerWallet()` because Alice already holds token #1.

Alice cannot receive any transferred subscription token unless she first transfers her own (expired) token away. Since there is no burn function, the only way to "clear" Alice's balance is to transfer her expired token to another address (e.g., a burn address).

This is the intended behavior of OnePerWallet, but it creates friction: expired-token holders become "stuck" and cannot receive transferred subscriptions without first disposing of their expired token.

**Proof of Concept**:
1. Alice calls `support(alice, 0, 1)` -- receives token #1.
2. Time passes, subscription expires. Alice still owns token #1.
3. Bob calls `support(bob, 0, 1)` -- receives token #2.
4. Bob calls `transferFrom(bob, alice, 2)` -- reverts with `OneTokenPerWallet()`.

**Recommendation**: Consider adding a `burn()` function (possibly only for expired tokens) so holders can clean up expired tokens before receiving a new one. Alternatively, document this as intended behavior: subscriptions are non-transferable to addresses that already hold a token.

---

## [NFT-5] Transferred token retains the original `startedAt` and `tierHistory` -- new owner inherits full history
**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `_update()` at `WithSupportTokens.sol:66-87`
**Description**: When a token is transferred, the `_update` override only updates the `subscription` mapping (lines 75-76) and notifies the hook of the tier change (lines 78-84). It does NOT reset `startedAt[tokenId]`, `tierHistory[tokenId]`, or `expiresAt[tokenId]`. The new owner inherits the full subscription history, including the original start date and all tier period records.

This means:
- `tokenURI()` will display the original `startedAt` date, making the new owner appear to have been a supporter since the original subscription began.
- The `_attributes` function in `SupportRenderer.sol:108` will include all historical tier periods from the original owner.
- The "DAY N" counter in the SVG (`SupportRenderer.sol:54`) continues from the original start date.

This is arguably by design (the token represents the subscription, not the supporter), but it could be misleading for social proof or loyalty tracking.

**Proof of Concept**:
1. Alice subscribes on Day 1 at Tier 0 for 12 months.
2. On Day 30, Alice upgrades to Tier 1.
3. On Day 60, Alice transfers the token to Bob.
4. Bob's `tokenURI()` shows "DAY 61" with tier history showing Alice's Tier 0 and Tier 1 periods.

**Recommendation**: If subscription history should belong to the owner rather than the token, reset `startedAt` and `tierHistory` on transfer. If the current behavior is intentional (token = portable subscription), document it clearly. Consider adding the original supporter address to the metadata so provenance is visible.

---

## [NFT-6] Excess ETH refund in `support()` is vulnerable to griefing via revert in recipient fallback
**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `support()` at `Support.sol:154-158`
**Description**: After processing a subscription, excess ETH is refunded to `msg.sender` via a low-level call: `(bool sent, ) = msg.sender.call{value: excess}("")`. If `msg.sender` is a contract with a reverting `receive()` or `fallback()` function, and they deliberately overpay, the entire `support()` transaction reverts.

This is primarily a self-griefing vector (the caller hurts themselves), but it could be used to grief third-party subscription flows. For example, if a meta-transaction relayer or a batching contract calls `support()` on behalf of users, a reverting refund would DoS the entire batch.

**Proof of Concept**:
1. Deploy a contract `Griefer` with `receive() external payable { revert(); }`.
2. From `Griefer`, call `support{value: 1 ether}(someRecipient, 0, 1)` where the actual cost is 0.5 ETH.
3. The refund of 0.5 ETH to `Griefer` reverts, causing the entire `support()` call to revert.

**Recommendation**: Use a pull-based refund pattern (store excess and let the user withdraw), or use OpenZeppelin's `Address.sendValue` with a try/catch that skips the refund on failure. Alternatively, accept this as the caller's own problem since they control whether they overpay.

---

## [NFT-7] `tokenOf()` in OnePerWallet returns incorrect value for token ID 0
**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `tokenOf()` at `OnePerWallet.sol:20-25`
**Description**: The `tokenOf` function stores `tokenId + 1` in `_ownedToken` to distinguish "holds token 0" from "holds no token" (since both would otherwise be 0). This means `_ownedToken[owner] == 0` means "no token" and `_ownedToken[owner] == 1` means "holds token 0".

In this system, token IDs start at 1 (from `++_subscriptionIdCounter`), so token ID 0 is never minted. This off-by-one encoding is therefore safe in practice. However, if the system were ever modified to mint token ID 0, the `tokenOf` function would work correctly (returning 0 when `_ownedToken[owner] == 1`).

**Proof of Concept**: Not exploitable in current system since token IDs start at 1.

**Recommendation**: No action required. The `tokenOf` encoding is correct and the system never mints token ID 0. This is purely informational.

---

## [NFT-8] `_update()` override chain: `WithSupportTokens` calls `super._update()` which resolves to `OnePerWallet._update()`, not `ERC721._update()`
**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `_update()` at `WithSupportTokens.sol:66-67`
**Description**: The MRO (Method Resolution Order) for `WithSupportTokens` is: `WithSupportTokens -> OnePerWallet -> ERC721`. When `WithSupportTokens._update()` calls `super._update(to, tokenId, auth)` at line 67, it dispatches to `OnePerWallet._update()`, which in turn calls `super._update()` to reach `ERC721._update()`.

This means the one-per-wallet check in `OnePerWallet._update()` executes BEFORE the subscription mapping updates in `WithSupportTokens._update()`. The order is:
1. `ERC721._update()` -- actual token transfer, balance updates
2. `OnePerWallet._update()` -- clears old owner tracking, checks `balanceOf(to) > 1`, sets new owner tracking
3. `WithSupportTokens._update()` -- updates `subscription` mapping, notifies hooks

This ordering is correct. The subscription state is updated after the token transfer succeeds and ownership constraints are validated.

**Proof of Concept**: Not an issue -- this is informational about the call chain.

**Recommendation**: No action required. Document the MRO dependency in a code comment for future maintainers, since reordering the inheritance could break the invariant.

---

## [NFT-9] Hook calls in `_update()` are not protected by the same guard as `_notifyHook()` in `support()`
**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `_update()` at `WithSupportTokens.sol:78-84`
**Description**: In `Support.sol:268-274`, the `_notifyHook` function checks `previousTier != NO_TIER && previousTier != tier` before calling `h.onRelease()`, and always calls `h.onSubscribe()`. However, in `WithSupportTokens._update()` (lines 78-84), the transfer hook notification calls `h.onRelease(tier, from)` and `h.onSubscribe(tier, to)` unconditionally (as long as the subscription was active), with the same tier for both calls.

This means on transfer, the hook receives `onRelease(tier, from)` followed by `onSubscribe(tier, to)` for the same tier. In `MaxSlotsHook`, this means:
- `onRelease` removes `from` from the tier holder list.
- `onSubscribe` adds `to` to the tier holder list.

This is correct behavior for a transfer. The MaxSlotsHook properly handles this case.

However, a subtle issue exists: the hook calls are made via external calls to a potentially malicious or buggy hook contract. If `h.onRelease()` reverts, the entire transfer reverts, meaning the hook can block token transfers. The owner can set any hook via `setHook()`.

**Proof of Concept**:
1. Owner sets a hook that reverts on `onRelease()` for a specific tier or address.
2. Any user holding an active subscription token at that tier cannot transfer their token -- all `transferFrom` / `safeTransferFrom` calls revert.
3. The user's token is effectively frozen until the owner changes the hook.

**Recommendation**: This is an owner-trust issue. The owner can already rug in several ways (set malicious renderer, set malicious hook, etc.). If reducing owner trust is desired, consider wrapping hook calls in a try/catch so that hook failures do not block transfers:
```solidity
if (wasActive) {
    ISubscriptionHook h = hook;
    if (address(h) != address(0)) {
        try h.onRelease(tier, from) {} catch {}
        try h.onSubscribe(tier, to) {} catch {}
    }
}
```

---

## [NFT-10] `tokenURI()` reverts for tokens with no tier history (should be unreachable)
**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `tokenURI()` at `WithSupportTokens.sol:40-59`, `_lastTier()` at `Support.sol:331-334`
**Description**: If `currentTier()` returns `active = false`, `tokenURI()` calls `_lastTier(tokenId)` at line 44. `_lastTier` accesses `periods[periods.length - 1]`, which would revert with an array-out-of-bounds error if `tierHistory[tokenId]` is empty.

In practice, this is unreachable because `_applySubscription()` always pushes at least one `TierPeriod` when creating or reactivating a subscription (lines 313 or 315). A token cannot exist without at least one tier period entry.

However, if `tierHistory[tokenId]` were somehow cleared (e.g., via a future code change or storage collision), `tokenURI()` would revert for that token, making it invisible to marketplaces and wallets.

**Proof of Concept**: Not triggerable with current code. Would require a code change that clears `tierHistory` without re-populating it.

**Recommendation**: Add a defensive check in `tokenURI()`:
```solidity
uint8 displayTier = active ? tier : (tierHistory[tokenId].length > 0 ? _lastTier(tokenId) : 0);
```

---

## [NFT-11] SupportRenderer `_buildSVG` can underflow if `block.timestamp < data.startedAt`
**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `_buildSVG()` at `SupportRenderer.sol:54`
**Description**: The day number calculation `(block.timestamp - data.startedAt) / 1 days + 1` at line 54 performs an unchecked subtraction. If `block.timestamp < data.startedAt` (which can happen when a subscription is granted with a future `startAt` via the `grant()` function at `Support.sol:162`), this subtraction underflows, causing a revert (Solidity 0.8.x checked arithmetic).

The `grant()` function allows the owner to set `startAt` to any `uint64` value, including timestamps in the future. If a token is granted with a future start date and someone calls `tokenURI()` before that date, the call reverts.

**Proof of Concept**:
1. Owner calls `grant(recipient, 0, 12, futureTimestamp)` where `futureTimestamp = block.timestamp + 30 days`.
2. Token is minted with `startedAt[tokenId] = futureTimestamp`.
3. Before `futureTimestamp`, anyone calling `tokenURI(tokenId)` gets a revert due to arithmetic underflow in `SupportRenderer._buildSVG()`.

**Recommendation**: Add a guard in `_buildSVG`:
```solidity
uint256 dayNum = block.timestamp > data.startedAt
    ? (block.timestamp - data.startedAt) / 1 days + 1
    : 0;
```
Or prevent `grant()` from setting a future `startAt` that would cause rendering issues.

---

## Summary

| ID | Title | Severity |
|----|-------|----------|
| NFT-1 | `_mint` used instead of `_safeMint` | Low |
| NFT-2 | Reentrancy via `_mint` callback if upgraded to `_safeMint` | Info |
| NFT-3 | Transfer subscription mapping analysis | Info |
| NFT-4 | OnePerWallet blocks transfers to expired-token holders | Medium |
| NFT-5 | Transferred token retains original history | Low |
| NFT-6 | Excess ETH refund griefing via reverting fallback | Low |
| NFT-7 | `tokenOf()` off-by-one encoding for token ID 0 | Info |
| NFT-8 | `_update()` override chain MRO documentation | Info |
| NFT-9 | Hook can block token transfers | Low |
| NFT-10 | `tokenURI()` reverts if tier history is empty | Info |
| NFT-11 | Renderer underflow on future-dated subscriptions | Low |

**Critical**: 0 | **High**: 0 | **Medium**: 1 | **Low**: 5 | **Info**: 5
