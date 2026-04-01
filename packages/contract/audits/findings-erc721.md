# ERC-721 Security Audit Findings

**Contracts audited:**
- `contracts/Support.sol`
- `contracts/SupportToken.sol`
- `contracts/extensions/WithSupportTokens.sol`
- `contracts/hooks/MaxSlotsHook.sol`
- `contracts/hooks/DiscountHook.sol`
- `contracts/interfaces/ISubscriptionHook.sol`
- `contracts/interfaces/ISupportRenderer.sol`
- `contracts/renderers/SupportRenderer.sol`

**Checklist:** `evm-audit-erc721`

---

## [NFT-1] `_mint` used instead of `_safeMint` -- tokens sent to contracts may be permanently locked

**Severity**: Medium
**Category**: evm-audit-erc721
**Location**: `WithSupportTokens._onNewSubscription()` at `extensions/WithSupportTokens.sol:141`

**Description**: The `_onNewSubscription` callback uses `_mint(recipient, tokenId)` instead of `_safeMint(recipient, tokenId)`. Per the ERC-721 standard, `_safeMint` calls `onERC721Received` on the recipient contract, allowing it to accept or reject the token. With `_mint`, if a third party calls `support(contractAddress, tier, duration)` for a contract recipient that does not implement `IERC721Receiver`, the token will be minted to that contract but will be permanently stuck -- the contract has no way to transfer it out.

This is particularly relevant because `support()` explicitly allows third parties to subscribe on behalf of others (`msg.sender != recipient` is a supported code path). A well-meaning supporter could lock an NFT inside a multisig, governance contract, or any contract that lacks ERC-721 receiver support.

**Proof of Concept**:
1. Deploy `SupportToken`.
2. Deploy a contract `Vault` that does not implement `IERC721Receiver`.
3. Call `support(address(vault), 0, 1)` with sufficient ETH.
4. Token is minted to `Vault` via `_mint`. No `onERC721Received` check occurs.
5. The token is now permanently locked in `Vault` since it has no transfer function.

**Recommendation**: Replace `_mint` with `_safeMint`:
```solidity
function _onNewSubscription(address recipient, uint256 tokenId) internal override {
    _safeMint(recipient, tokenId);
}
```
Note: If `_safeMint` is used, the `_update` override and any state changes before the mint in `_applySubscription` should be reviewed for reentrancy via the `onERC721Received` callback (see NFT-2).

---

## [NFT-2] Reentrancy via excess ETH refund in `support()` after state changes

**Severity**: Medium
**Category**: evm-audit-erc721
**Location**: `Support.support()` at `Support.sol:154-158`

**Description**: The `support()` function performs an external call to refund excess ETH to `msg.sender` via `msg.sender.call{value: excess}("")` at line 156. This happens after all state changes (`_applySubscription`, `_notifyHook`, `_afterSubscriptionChange`) and after the `Supported` event is emitted. While the state is fully updated before the refund (following checks-effects-interactions pattern), this external call hands control to `msg.sender`, who could reenter `support()`.

In the current implementation, reentrancy during the refund would simply create a second valid subscription (since state is already finalized). However, this could interact poorly with hook contracts. For example, the `MaxSlotsHook.onSubscribe()` function modifies state (`_tierHolders`, `_tierHolderIndex`) and a reentrant call could cause the hook to double-count or corrupt its holder array if the same address subscribes again before the first transaction completes.

Additionally, if `_safeMint` were adopted (per NFT-1), the `onERC721Received` callback on the recipient would execute mid-transaction (inside `_applySubscription`), before the refund, before hook notification, and before the event -- creating a more dangerous reentrancy window where subscription state is partially applied.

**Proof of Concept**:
1. Deploy `SupportToken` with `MaxSlotsHook` attached.
2. Create a malicious contract that implements `receive()` to call `support()` again.
3. Call `support()` with excess ETH. After state is finalized, the refund triggers `receive()`.
4. The reentrant `support()` call executes with the first call's state already committed.
5. With `MaxSlotsHook`, the reentrant call could push the same subscriber twice into `_tierHolders` if timing aligns with index checks.

**Recommendation**: Add a reentrancy guard (`nonReentrant` from OpenZeppelin's `ReentrancyGuard`) to the `support()` function:
```solidity
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Add to contract inheritance
abstract contract Support is Ownable2Step, HasPriceFeed, WithSaleStart, ReentrancyGuard {
    ...
    function support(...) external payable afterSaleStart nonReentrant {
```

---

## [NFT-3] `tokenURI` depends on external renderer contract -- untrusted renderer can DoS or return malicious data

**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `WithSupportTokens.tokenURI()` at `extensions/WithSupportTokens.sol:45-64`

**Description**: The `tokenURI` function delegates entirely to an external `renderer` contract via `renderer.tokenURI(data)`. The renderer address is set by the owner via `setRenderer()` and there is no validation that the address implements `ISupportRenderer` or is a contract at all. If the renderer is set to a non-contract address, the call will succeed but return empty data. If the renderer is set to a malicious or buggy contract, it could:
1. Revert on every call, making `tokenURI` always fail (DoS for metadata).
2. Consume excessive gas.
3. Return arbitrarily large data.

Since `setRenderer` is `onlyOwner`, this is limited to owner misconfiguration or a compromised owner key. However, marketplaces and indexers that call `tokenURI` would be affected.

**Proof of Concept**:
1. Owner calls `setRenderer(address(0))`.
2. Any call to `tokenURI(tokenId)` reverts because `address(0)` has no code.
3. All NFT metadata becomes unavailable on marketplaces.

**Recommendation**: Add a zero-address check and optionally an interface check in `setRenderer`:
```solidity
function setRenderer(address _renderer) external onlyOwner {
    require(_renderer != address(0), "Invalid renderer");
    renderer = ISupportRenderer(_renderer);
    emit RendererUpdated(_renderer);
}
```

---

## [NFT-4] SVG injection via owner-controlled `logo` string in `SupportRenderer._badge()`

**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `SupportRenderer._badge()` at `renderers/SupportRenderer.sol:48-68`

**Description**: The `logo` string is embedded directly into the SVG output without any sanitization at line 65: `'<g transform="translate(3,3)">', logo, '</g>'`. The `logo` is set by the contract owner via `setLogo()`. While `projectName` is properly escaped using `LibString.escapeHTML()`, the `logo` field is not.

A malicious or compromised owner could set `logo` to a string containing:
- `</svg><script>...</script><svg>` -- injecting JavaScript into SVG (relevant for marketplace rendering)
- Excessively large SVG content causing rendering issues
- SVG elements that break out of the `<g>` container

Since this is owner-controlled, the risk is limited to owner misbehavior. However, the inconsistency between sanitizing `projectName` but not `logo` suggests the `logo` field was overlooked.

**Proof of Concept**:
1. Owner calls `setLogo('</g></svg><script>alert("xss")</script><svg><g>')`.
2. Any call to `tokenURI` returns an SVG with injected script tags.
3. Marketplaces rendering this SVG inline could execute the script (most modern marketplaces sanitize, but not all).

**Recommendation**: The `logo` is expected to be an SVG fragment (e.g., `<svg>...</svg>` or `<path .../>`) set by the trusted owner. If the trust model is acceptable, document it clearly. Otherwise, consider validating or sanitizing the logo content, or storing it as a pre-encoded base64 image reference instead of raw SVG.

---

## [NFT-5] `ERC721Enumerable` gas cost scales with holder balance in `_update`, `_transferActiveToken`, and `_receiveActiveToken`

**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `WithSupportTokens._transferActiveToken()` at `extensions/WithSupportTokens.sol:103-116`, `_receiveActiveToken()` at lines 121-136, `_activeTokenOf()` at lines 148-163

**Description**: Multiple functions iterate over all tokens owned by an address using `tokenOfOwnerByIndex()`:
- `_transferActiveToken`: scans all tokens of `from` to find a replacement active token.
- `_receiveActiveToken`: scans all tokens of `to` to check if any existing token is active.
- `_activeTokenOf`: scans all tokens of `supporter` to find an active one.

Combined with `ERC721Enumerable`'s own O(n) `_update` overhead for maintaining enumeration mappings, transfers become increasingly expensive as users accumulate tokens (which never burn). A user who has been re-subscribed many times (each creating a new token) will have a growing token balance, and every transfer or subscription resolution will iterate through all of them.

Additionally, `MaxSlotsHook._isActiveOnTier()` calls `activeTokenOf()` which triggers this scan. `MaxSlotsHook.onSubscribe()` iterates all holders and calls `_isActiveOnTier()` for each -- creating O(holders * tokens_per_holder) complexity.

**Proof of Concept**:
1. Subscribe address `A` for 1 month, let it expire. Repeat 100 times. Address `A` now holds 100 expired tokens.
2. Subscribe address `A` again (token 101). Call `support()` -- `_resolveSubscription` calls `_syncActiveToken` which calls `_activeTokenOf`, scanning all 101 tokens.
3. Transfer token 101 from `A` to `B`. `_transferActiveToken` scans 101 tokens. `_receiveActiveToken` scans `B`'s tokens.
4. Gas cost grows linearly with the number of historical (expired) tokens held.

**Recommendation**: Consider limiting the iteration or maintaining an explicit pointer to the active token that avoids full scans. The `activeToken[address]` mapping already serves this purpose but is not consistently trusted -- `_activeTokenOf` falls through to a full scan when the cached pointer is stale. An alternative approach is to eagerly update the pointer on expiration or keep a bounded scan window.

---

## [NFT-6] Tokens are never burned -- permanent state growth and stale NFT accumulation

**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `WithSupportTokens.sol` (entire contract)

**Description**: There is no mechanism to burn expired subscription tokens. Once minted, tokens exist forever even after the subscription they represent has expired. This means:
1. `totalSupply()` only increases, never decreases, and does not reflect active subscriptions.
2. Users accumulate expired tokens in their wallets, cluttering portfolio views and increasing gas costs for enumeration (see NFT-5).
3. Expired tokens still have valid `tokenURI` (showing "EXPIRED" status) and remain transferable.

While this is a design choice (expired tokens serve as historical records), it has implications for protocols or integrations that use `totalSupply()` or `balanceOf()` to infer active participation.

**Proof of Concept**: N/A -- this is a design observation.

**Recommendation**: Consider adding an optional `burn(uint256 tokenId)` function that allows the token holder to destroy their expired tokens, or a batch cleanup mechanism. At minimum, document that `totalSupply()` includes expired tokens and should not be used to count active subscribers.

---

## [NFT-7] Hook `onSubscribe` can revert and block subscriptions or transfers

**Severity**: Medium
**Category**: evm-audit-erc721
**Location**: `WithSupportTokens._update()` at `extensions/WithSupportTokens.sol:87-96`, `Support._notifyHook()` at `Support.sol:273-279`

**Description**: The hook's `onSubscribe()` and `onRelease()` calls are not wrapped in try/catch. A malicious or buggy hook contract can revert, which will:

1. **Block all new subscriptions**: `support()` calls `_notifyHook()` which calls `h.onSubscribe()`. If the hook reverts, no one can subscribe.
2. **Block all NFT transfers**: `_update()` calls `h.onRelease()` and `h.onSubscribe()` for active tokens. If the hook reverts, no transfer of active tokens is possible -- effectively freezing NFTs.

While the hook is set by the owner (trusted), this creates a single point of failure. The `MaxSlotsHook.onSubscribe()` function can revert with `TierFull()` -- this is intentional for subscriptions but also blocks transfers of active tokens between users, which may not be intended.

**Proof of Concept**:
1. Deploy `SupportToken` with `MaxSlotsHook` set to `maxSlots[0] = 1`.
2. Address `A` subscribes to tier 0 (takes the single slot).
3. Address `A` tries to transfer the active token to address `B`.
4. In `_update()`, the hook's `onRelease(0, A)` removes `A` from the tier, then `onSubscribe(0, B)` is called.
5. If the tier is already full due to another subscriber joining between the release and subscribe, the transfer reverts with `TierFull()`.
6. Even without race conditions, the `onSubscribe` in `_update` calls `h.onSubscribe(tier, to)` only if `_hasActiveTierToken(to, tier)` is true -- but `_hasActiveTierToken` checks the token being transferred which is now owned by `to` (since `super._update` already moved it). This means the hook will try to add `to` as a tier holder, which could fail if slots are full.

**Recommendation**: Consider wrapping hook calls in `_update()` with try/catch so that hook failures do not freeze token transfers:
```solidity
if (address(h) != address(0)) {
    if (!_hasActiveTierToken(from, tier)) {
        try h.onRelease(tier, from) {} catch {}
    }
    if (_hasActiveTierToken(to, tier)) {
        try h.onSubscribe(tier, to) {} catch {}
    }
}
```
Alternatively, document that hook contracts must never revert unexpectedly and that `MaxSlotsHook` intentionally blocks transfers when tiers are full.

---

## [NFT-8] `_update` hook notification logic has inconsistent tier tracking on transfer

**Severity**: Low
**Category**: evm-audit-erc721
**Location**: `WithSupportTokens._update()` at `extensions/WithSupportTokens.sol:75-100`

**Description**: In `_update()`, when a token is transferred, the code calls `_hasActiveTierToken(to, tier)` at line 93 to decide whether to notify the hook about the new holder. However, by this point, `super._update(to, tokenId, auth)` has already executed (line 76), which means the ERC721Enumerable state has already moved the token to `to`. So `_hasActiveTierToken(to, tier)` will find the just-transferred token in `to`'s balance, meaning `h.onSubscribe(tier, to)` is always called for active token transfers -- even if `to` already had another active token of the same tier.

Conversely, `_hasActiveTierToken(from, tier)` at line 90 checks after the token has been removed from `from`, so `h.onRelease(tier, from)` is correctly only called when `from` has no remaining active tokens of that tier.

The asymmetry means: if `to` already holds an active tier-X token and receives another tier-X token via transfer, `onSubscribe(tier, to)` will be called again. For `MaxSlotsHook`, this is handled (the index check returns early if the subscriber is already registered), but other hook implementations might double-count.

**Proof of Concept**:
1. Address `B` has an active tier-0 token (token 1).
2. Address `A` transfers their active tier-0 token (token 2) to `B`.
3. In `_update()`, `_hasActiveTierToken(B, 0)` returns true (because `B` now holds both token 1 and token 2).
4. `h.onSubscribe(0, B)` is called even though `B` was already subscribed to tier 0.
5. `MaxSlotsHook.onSubscribe` returns early due to the index check, but a custom hook without this guard could corrupt state.

**Recommendation**: Check whether `to` already had an active token of the given tier *before* the transfer, or document that hook `onSubscribe` implementations must be idempotent for the same `(tier, subscriber)` pair.

---

## [NFT-9] `activeToken` mapping can become stale for the receiver on transfer, breaking subscription resolution

**Severity**: Medium
**Category**: evm-audit-erc721
**Location**: `WithSupportTokens._receiveActiveToken()` at `extensions/WithSupportTokens.sol:121-136`

**Description**: When a token is transferred to address `to`, `_receiveActiveToken` only assigns the incoming token as `activeToken[to]` if `to` has no existing active token. The check at line 124-125 is:
```solidity
uint256 existing = activeToken[to];
if (existing != 0 && block.timestamp < expiresAt[existing]) return;
```

However, `activeToken[to]` could be pointing to a token that `to` no longer owns (it was transferred away in a previous transaction), but which hasn't expired. In this case, `_receiveActiveToken` would see a non-zero, non-expired `existing` and return early -- failing to set the incoming token as active. This means `to` could have their `activeToken` pointing to a token they don't own.

When `_resolveSubscription` is later called for `to`, it calls `_syncActiveToken` -> `_activeTokenOf`, which does a full scan and would find the correct token. But between the transfer and the next subscription action, `activeToken[to]` is stale and `activeTokenOf(to)` (the public view function which calls `_activeTokenOf`) would still return the correct value due to the scan fallback. The stale pointer is corrected lazily.

The issue is that external contracts reading `activeToken[to]` directly (the public mapping) would get incorrect data. `MaxSlotsHook._isActiveOnTier()` calls `activeTokenOf()` (the view function with the scan), so it is not affected. But any integration reading the raw `activeToken` mapping would be misled.

**Proof of Concept**:
1. Address `A` has active token 1 (tier 0). `activeToken[A] = 1`.
2. `A` transfers token 1 to `B`. `_transferActiveToken(A, 1)` sets `activeToken[A] = 0`. `_receiveActiveToken(B, 1)` sets `activeToken[B] = 1`.
3. `B` transfers token 1 to `C`. `_transferActiveToken(B, 1)` sets `activeToken[B] = 0`. `_receiveActiveToken(C, 1)` sets `activeToken[C] = 1`.
4. `C` transfers token 1 back to `B`. `_receiveActiveToken(B, 1)` checks: `activeToken[B] == 0`, so it proceeds to scan and assigns `activeToken[B] = 1`. This works correctly.
5. Now consider: `B` has token 1 (active) and token 2 (active). `activeToken[B] = 1`. `B` transfers token 1 to `C`. `_transferActiveToken(B, 1)` scans and finds token 2, sets `activeToken[B] = 2`. Correct.
6. But: `B` has token 1 (active). `activeToken[B] = 1`. `B` receives token 2 (active) from `D`. `_receiveActiveToken(B, 2)`: `existing = activeToken[B] = 1`, and `expiresAt[1]` is in the future, so it returns early. `activeToken[B]` remains `1`. This is correct since `B` still owns token 1.

After deeper analysis, the lazy-sync pattern works correctly through `_activeTokenOf` for all contract interactions. The risk is limited to off-chain readers of the raw `activeToken` mapping getting stale data, which is an informational concern.

**Revised Severity**: Low

**Recommendation**: Document that `activeToken` is a cached pointer and external consumers should use `activeTokenOf()` instead of reading the mapping directly.

---

## [NFT-10] No `from` parameter validation in `transferFrom` -- relies on OpenZeppelin's internal checks

**Severity**: Info
**Category**: evm-audit-erc721
**Location**: `WithSupportTokens.sol` (inherited ERC721)

**Description**: The contracts inherit OpenZeppelin's ERC721 which correctly validates that `from` is the actual owner in `transferFrom(from, to, tokenId)`. The checklist item "Most `from` parameters should be `msg.sender`" does not apply here because the contract does not expose any custom transfer function with a user-supplied `from` parameter -- it relies entirely on the standard ERC721 `transferFrom` which is secure. This is informational confirmation that this checklist item is satisfied.

**Proof of Concept**: N/A.

**Recommendation**: No action needed.
