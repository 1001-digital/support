# Access Control Audit Findings

Audit of the Support protocol contracts against the `evm-audit-access-control` checklist.

**Contracts in scope:**
- `Support.sol`
- `SupportToken.sol`
- `WithSupportTokens.sol`
- `MaxSlotsHook.sol`
- `DiscountHook.sol`
- `ISubscriptionHook.sol`

---

## [AC-1] Malicious or buggy hook can permanently DoS all subscriptions and token transfers
**Severity**: High
**Category**: evm-audit-access-control
**Location**: `Support.sol:273-278` (`_notifyHook`), `WithSupportTokens.sol:88-96` (`_update`)
**Description**: The hook contract is called during critical paths -- `support()`, `grant()`, and ERC-721 token transfers -- without any try/catch protection. If the hook's `onSubscribe()` or `onRelease()` functions revert (whether maliciously or due to a bug), all subscriptions, tier changes, and token transfers are permanently blocked. Since the owner can set the hook to `address(0)` to recover, this requires owner intervention. However, if the owner key is compromised and a malicious hook is set, users' tokens become non-transferable and no new subscriptions can be created until the owner acts.

In `_notifyHook()`:
```solidity
h.onRelease(previousTier, recipient);  // can revert, blocking the entire tx
h.onSubscribe(tier, recipient);         // can revert, blocking the entire tx
```

In `WithSupportTokens._update()`:
```solidity
h.onRelease(tier, from);    // can revert, blocking token transfer
h.onSubscribe(tier, to);    // can revert, blocking token transfer
```

**Proof of Concept**:
1. Owner sets a hook contract whose `onSubscribe()` always reverts.
2. All calls to `support()`, `grant()`, and ERC-721 `transferFrom()` / `safeTransferFrom()` revert.
3. Users cannot subscribe, change tiers, or transfer their tokens.
4. The only recovery path is for the owner to call `setHook(address(0))`.

**Recommendation**: Wrap hook calls in try/catch so that a failing hook does not block core protocol operations. Alternatively, use a gas-limited call to prevent hooks from consuming all gas.
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

---

## [AC-2] Hook can manipulate subscription pricing and duration without constraints
**Severity**: Medium
**Category**: evm-audit-access-control
**Location**: `Support.sol:356-364` (`_beforeSubscribe`), `ISubscriptionHook.sol:9-13`
**Description**: The hook's `beforeSubscribe()` function returns `Adjustments` that fully control the final USD price, subscription duration, and start time. There are no bounds checks on the returned values. A malicious hook can:
- Set `adjustedUSD = 0` to make all subscriptions free, draining expected revenue.
- Set `adjustedUSD` to an extremely high value, making subscriptions unaffordable.
- Set `adjustedDuration = 0` for same-tier renewals, causing users to pay for zero additional time.
- Set `adjustedStart` to a timestamp far in the past or future, manipulating expiry calculations.

This is a trust model concern: anyone relying on this protocol must trust not just the owner, but also the currently deployed hook contract's logic.

**Proof of Concept**:
1. Owner deploys a hook that returns `adjustedUSD = 0` for all subscriptions.
2. Users subscribe for free, the protocol collects no revenue.
3. Alternatively, the hook returns `adjustedDuration = 0` and `adjustedUSD = baseUSD` for renewals.
4. Users pay full price but get zero additional subscription time.

**Recommendation**: Add sanity bounds on the values returned by `beforeSubscribe()` in `Support.sol`:
```solidity
ISubscriptionHook.Adjustments memory adj = h.beforeSubscribe(tier, duration, baseUSD, subscriber, isNew, previousTier);
require(adj.adjustedDuration <= duration * 2, "Hook: duration out of range");
require(adj.adjustedUSD <= baseUSD * 2, "Hook: price out of range");
```
At minimum, ensure `adjustedDuration > 0` when duration is required (new subscriptions and same-tier renewals).

---

## [AC-3] Instant critical parameter changes without timelock
**Severity**: Medium
**Category**: evm-audit-access-control
**Location**: `Support.sol:219-229` (`setTierPrice`, `setHook`)
**Description**: The owner can instantly change tier prices and the hook contract with no timelock or delay. This gives the owner the ability to:
- Change `setTierPrice()` to raise prices immediately before a user's pending transaction, causing them to overpay or have their transaction revert.
- Change `setHook()` to a malicious hook that manipulates pricing, blocks subscriptions, or freezes token transfers (see AC-1 and AC-2).

Users have no time to react to these changes. While events are emitted (`TierPriceUpdated`, `HookUpdated`), they provide no advance warning.

**Proof of Concept**:
1. A user submits a `support()` transaction expecting to pay based on current tier prices.
2. The owner front-runs with `setTierPrice()` to double the price.
3. The user's transaction either reverts (insufficient payment) or the user overpays for a worse deal.

**Recommendation**: Implement a timelock pattern for critical parameter changes, or at minimum a two-step process with a delay:
```solidity
uint256 public constant TIMELOCK_DELAY = 2 days;
mapping(bytes32 => uint256) public pendingChanges;

function proposeHook(ISubscriptionHook _hook) external onlyOwner {
    bytes32 key = keccak256(abi.encode("setHook", _hook));
    pendingChanges[key] = block.timestamp + TIMELOCK_DELAY;
}

function executeSetHook(ISubscriptionHook _hook) external onlyOwner {
    bytes32 key = keccak256(abi.encode("setHook", _hook));
    require(pendingChanges[key] != 0 && block.timestamp >= pendingChanges[key], "Timelock");
    delete pendingChanges[key];
    hook = _hook;
    emit HookUpdated(address(_hook));
}
```

---

## [AC-4] Compromised owner can drain all protocol funds and brick subscriptions
**Severity**: Medium
**Category**: evm-audit-access-control
**Location**: `Support.sol:244-249` (`withdraw`), `Support.sol:226-229` (`setHook`), `Support.sol:219-223` (`setTierPrice`)
**Description**: A single compromised owner key can perform the following destructive actions with no checks or delays:
1. Call `withdraw()` to drain all collected ETH.
2. Call `setHook()` to a malicious hook that blocks all subscriptions and token transfers (see AC-1).
3. Call `setTierPrice()` to set all prices to `type(uint128).max`, making subscriptions unaffordable.
4. Call `setRenderer()` to a malicious renderer that returns garbage metadata.

While `Ownable2Step` is used to prevent accidental ownership transfer, there is no multisig requirement or timelock. The owner is a single point of failure for the entire protocol.

**Proof of Concept**:
1. Attacker compromises the owner private key.
2. Attacker calls `withdraw()` to take all ETH.
3. Attacker calls `setHook(maliciousHook)` where `maliciousHook.onSubscribe()` always reverts.
4. All subscriptions, tier changes, and token transfers are permanently blocked.

**Recommendation**: Use a multisig wallet (e.g., Gnosis Safe) as the owner. Combine with a timelock for `setHook()` and `setTierPrice()` changes. Consider separating roles so that fund withdrawal requires a different authorization than parameter changes.

---

## [AC-5] Hook contracts use single-step Ownable instead of Ownable2Step
**Severity**: Low
**Category**: evm-audit-access-control
**Location**: `MaxSlotsHook.sol:14` (`contract MaxSlotsHook is ISubscriptionHook, Ownable`), `DiscountHook.sol:9` (`contract DiscountHook is ISubscriptionHook, Ownable`)
**Description**: Both `MaxSlotsHook` and `DiscountHook` inherit from OpenZeppelin's `Ownable` rather than `Ownable2Step`. The main `Support` contract correctly uses `Ownable2Step` for safe ownership transfer, but the hook contracts do not follow the same pattern. A single-step `transferOwnership()` to an incorrect address permanently locks out the hook owner, making the hook's admin functions (e.g., `setMaxSlots()`, `setDiscount()`) inaccessible.

**Proof of Concept**:
1. Hook owner calls `transferOwnership(wrongAddress)` on `MaxSlotsHook`.
2. Ownership is immediately transferred to `wrongAddress`.
3. `setMaxSlots()` is no longer callable by the original owner.
4. The hook cannot be reconfigured. The Support contract owner would need to deploy a new hook and call `setHook()`.

**Recommendation**: Use `Ownable2Step` for hook contracts, consistent with the main Support contract:
```solidity
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract MaxSlotsHook is ISubscriptionHook, Ownable2Step {
    // ...
}
```

---

## [AC-6] Hook contracts do not override renounceOwnership, allowing permanent lockout
**Severity**: Low
**Category**: evm-audit-access-control
**Location**: `MaxSlotsHook.sol:14`, `DiscountHook.sol:9`
**Description**: The main `Support` contract correctly overrides `renounceOwnership()` to revert (line 103-105), preventing accidental permanent lockout. However, `MaxSlotsHook` and `DiscountHook` inherit `Ownable` without overriding `renounceOwnership()`. If the hook owner accidentally or maliciously calls `renounceOwnership()`:
- On `MaxSlotsHook`: `setMaxSlots()` becomes permanently inaccessible. The slot limits are frozen forever.
- On `DiscountHook`: `setDiscount()` becomes permanently inaccessible. Discount parameters are frozen forever.

While the Support contract owner can replace the hook via `setHook()`, this requires deploying a new hook contract and migrating any state.

**Proof of Concept**:
1. Owner of `MaxSlotsHook` calls `renounceOwnership()`.
2. `setMaxSlots()` is permanently disabled since it requires `onlyOwner`.
3. The MaxSlotsHook cannot be reconfigured. A new hook must be deployed and set.

**Recommendation**: Override `renounceOwnership()` to revert in both hook contracts:
```solidity
function renounceOwnership() public pure override {
    revert();
}
```

---

## [AC-7] DiscountHook lacks onlySupport modifier on onSubscribe and onRelease
**Severity**: Low
**Category**: evm-audit-access-control
**Location**: `DiscountHook.sol:40-41`
**Description**: Unlike `MaxSlotsHook` which properly restricts `onSubscribe()` and `onRelease()` with the `onlySupport` modifier, `DiscountHook` leaves these functions callable by anyone:

```solidity
function onSubscribe(uint8, address) external override {}
function onRelease(uint8, address) external override {}
```

Currently these are no-op functions, so there is no immediate exploit. However, this represents a missing access control pattern that could become dangerous if the `DiscountHook` is later modified to track state in these callbacks (e.g., tracking active subscriber counts for volume-based discounts). The inconsistency with `MaxSlotsHook` suggests this was an oversight.

**Proof of Concept**: Not currently exploitable since the functions are no-ops. The risk is latent: if a developer adds state-modifying logic to these callbacks in a future version without adding `onlySupport`, anyone could manipulate the hook's state.

**Recommendation**: Add the `onlySupport` modifier for defense-in-depth, matching the pattern used in `MaxSlotsHook`:
```solidity
address public immutable support;

modifier onlySupport() {
    if (msg.sender != support) revert OnlySupport();
    _;
}

constructor(address _support, uint16 _minMonths, uint16 _percentOff) Ownable(msg.sender) {
    support = _support;
    // ...
}

function onSubscribe(uint8, address) external override onlySupport {}
function onRelease(uint8, address) external override onlySupport {}
```

---

## [AC-8] Third-party grief vector: anyone can extend a subscription, preventing natural expiry
**Severity**: Info
**Category**: evm-audit-access-control
**Location**: `Support.sol:112-159` (`support`)
**Description**: The `support()` function allows any address to pay for and extend another user's subscription at their current tier. While tier changes by third parties are correctly restricted (line 118-120), same-tier extensions are not. This means:
- A third party can prevent a user's subscription from expiring by continuously extending it.
- The third party pays for this, so there is no direct fund loss.
- The recipient can still change their own tier.

This is documented behavior (the natspec states "Third parties can extend or start subscriptions"), but users should be aware that their subscription expiry is not fully under their control. In scenarios where a user wants to "opt out" and let a subscription lapse (e.g., to avoid being listed as an active supporter), a third party can prevent this.

**Proof of Concept**:
1. Alice has a tier-2 subscription expiring in 1 day and wants it to expire.
2. Bob calls `support(alice, 2, 1)` paying for 1 month of tier-2.
3. Alice's subscription is extended by 1 month against her will.
4. Alice cannot force the subscription to end early.

**Recommendation**: Consider adding an opt-out mechanism where users can signal they do not want third-party extensions:
```solidity
mapping(address => bool) public optedOut;

function setOptOut(bool _optOut) external {
    optedOut[msg.sender] = _optOut;
}
```
Then in `support()`:
```solidity
if (msg.sender != recipient && optedOut[recipient]) revert RecipientOptedOut();
```
