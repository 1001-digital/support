# Access Control Audit Findings

**Scope**: Support.sol, SupportToken.sol, WithSupportTokens.sol, SupportRenderer.sol, DiscountHook.sol, EvmNowSupporterHook.sol, MaxSlotsHook.sol, and all interfaces.

**Checklist**: evm-audit-access-control

---

## Checklist Walkthrough

### Centralization Risks

- [x] **Admin can perform token transfers on behalf of users**: Not applicable. There is no admin function that calls `transfer()` or `transferFrom()` on user tokens. The `withdraw()` function (Support.sol:239) only sends collected ETH to `owner()`, not user tokens.
- [x] **Instant parameter changes without timelock**: **Finding AC-1 below.** Owner can instantly change tier prices (`setTierPrice`), hooks (`setHook`), the price feed (`setPriceFeed`), the renderer (`setRenderer`), and discount parameters (`setDiscount`). No timelock or governance delay.
- [x] **Total upgradeability**: Not applicable. No proxy pattern is used; contracts are not upgradeable.
- [x] **Pausing that blocks critical user operations**: **Finding AC-2 below.** There is no pause mechanism at all.
- [x] **Corrupted owner can destroy the protocol**: **Finding AC-3 below.** A compromised owner can drain all ETH, change hooks to block subscriptions, change the price feed to a malicious oracle, and set prices to near-zero.

### Privilege Escalation

- [x] **Missing access controls on sensitive functions**: **Finding AC-4 below.** DiscountHook's `onSubscribe()` and `onRelease()` have no access control, unlike MaxSlotsHook which correctly uses `onlySupport`.
- [x] **Two-step ownership transfer not implemented**: Support.sol correctly uses `Ownable2Step` (line 4, 25, 95-101). **However**, SupportRenderer (line 12) and DiscountHook (line 9) use plain `Ownable` without `Ownable2Step`. **Finding AC-5 below.**
- [x] **Functions operating on other users assume msg.sender is the user**: **Finding AC-6 below.** The `support()` function (Support.sol:112) allows anyone to subscribe on behalf of another address. Tier change is restricted to recipient/owner, but new subscriptions and renewals are open.
- [x] **Whitelist bypass via proxy tokens**: Not applicable. No address-based whitelist mechanism.

### Role Management

- [x] **Roles granted in constructor but not documented**: SupportRenderer (line 29) and DiscountHook (line 18) grant ownership to `msg.sender` in the constructor. The main Support contract takes `_initialOwner` as a parameter (line 82-86), which is more explicit. **Finding AC-7 below.**
- [x] **No cap on privileged role count**: Not applicable. Single-owner pattern; no role-granting with unbounded membership.
- [x] **Renounce ownership can brick contract**: Support.sol properly disables `renounceOwnership()` at line 103-105 by reverting. **However**, SupportRenderer and DiscountHook/EvmNowSupporterHook inherit plain `Ownable` and do NOT disable `renounceOwnership()`. **Finding AC-8 below.**

### Initialization & Deployment

- [x] **Initializer can be called by anyone on implementation contract**: Not applicable. No proxy/initializer pattern.
- [x] **Deploy scripts not included in audit scope**: No deployment scripts found in the repository (no `deploy/` directory). Only `scripts/render-nft.ts` exists. **Finding AC-9 below.**

### Multi-Agent Access

- [x] **When all agents are the same person**: The owner of Support, DiscountHook, MaxSlotsHook, and SupportRenderer can be different addresses. If one entity controls all, they have full control over pricing, discounts, slot limits, and rendering. Not a vulnerability per se, but the trust model should be documented.

---

## Findings

## [AC-1] Owner Can Instantly Change Critical Parameters Without Timelock
**Severity**: Medium
**Category**: evm-audit-access-control
**Location**: `setTierPrice()` at Support.sol:218, `setHook()` at Support.sol:233, `setPriceFeed()` at HasPriceFeed.sol:27, `setDiscount()` at DiscountHook.sol:47
**Description**: The owner can instantly change tier prices, the subscription hook contract, the Chainlink price feed address, and discount parameters. Active subscribers have no time to react to these changes. For example, the owner could change the price feed to a malicious oracle that returns an extremely high ETH/USD price, causing `_usdToEth()` to return near-zero ETH costs, effectively giving away subscriptions for free. Conversely, setting the price feed to one returning an extremely low ETH/USD price would make subscriptions prohibitively expensive, functioning as a de facto DoS. Changing the hook via `setHook()` can also immediately alter discount logic or block new subscriptions entirely.
**Proof of Concept**:
1. Owner calls `setPriceFeed(maliciousOracle)` where the oracle returns `price = 1` (1e-8 USD per ETH).
2. All subsequent `support()` calls compute `_usdToEth()` with a grossly inflated ETH price, making subscriptions cost enormous amounts of ETH.
3. Existing subscribers approaching renewal cannot renew at a reasonable cost.

Alternatively:
1. Owner calls `setHook(maliciousHook)` where `beforeSubscribe()` always reverts.
2. No new subscriptions or renewals are possible.
**Recommendation**: Consider implementing a timelock for critical parameter changes, or at minimum, emit events before changes take effect so off-chain monitoring can alert subscribers. A pattern like OpenZeppelin's `TimelockController` or a two-step parameter change with a delay would be appropriate:
```solidity
uint256 public constant TIMELOCK_DELAY = 2 days;
mapping(bytes32 => uint256) public pendingChanges;

function proposeTierPrice(uint8 tier, uint128 priceUSD) external onlyOwner {
    bytes32 key = keccak256(abi.encode("tierPrice", tier));
    pendingChanges[key] = block.timestamp + TIMELOCK_DELAY;
    // emit event
}
```

## [AC-2] No Pause Mechanism for Emergency Response
**Severity**: Low
**Category**: evm-audit-access-control
**Location**: `support()` at Support.sol:112, `withdraw()` at Support.sol:239
**Description**: The contract has no pause functionality. If a critical vulnerability is discovered in the hook contract, price feed, or the subscription logic itself, the owner has no way to temporarily halt operations. The only emergency lever is `setHook(address(0))` to disable hooks, but this does not prevent new subscriptions or withdrawals. In a scenario where the price feed is compromised (returning stale or manipulated data), subscriptions could be created at incorrect prices with no way to stop them.
**Proof of Concept**: If the Chainlink price feed returns manipulated data (flash-loan-based oracle manipulation on a less liquid pair, or a feed outage returning stale data that passes the 1-hour staleness check), an attacker could:
1. Call `support()` at a massively discounted ETH cost.
2. The owner cannot pause to prevent this; they can only race to call `setPriceFeed()` to switch to a different oracle.
**Recommendation**: Add a `Pausable` modifier from OpenZeppelin to the `support()` function:
```solidity
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// Add `whenNotPaused` to `support()`:
function support(address recipient, uint8 tier, uint32 duration)
    external payable afterSaleStart whenNotPaused { ... }

function pause() external onlyOwner { _pause(); }
function unpause() external onlyOwner { _unpause(); }
```
Note: `withdraw()` should NOT be paused, so the owner can always extract funds in an emergency.

## [AC-3] Compromised Owner Key Can Drain All Funds and Brick the Contract
**Severity**: Medium
**Category**: evm-audit-access-control
**Location**: `withdraw()` at Support.sol:239, `setHook()` at Support.sol:233, `setPriceFeed()` at HasPriceFeed.sol:27, `setTierPrice()` at Support.sol:218
**Description**: If the owner's private key is compromised, the attacker can: (1) call `withdraw()` to drain all accumulated ETH, (2) call `setHook()` with a malicious hook that reverts on all calls, permanently blocking subscriptions, (3) call `setPriceFeed()` to point to a malicious oracle, and (4) call `setTierPrice()` to set prices to 1 wei (the minimum non-zero value). The `Ownable2Step` pattern protects against accidental transfer, but a compromised key has full unilateral control. There is no multisig requirement, no timelock, and `renounceOwnership` is disabled so the attacker cannot even lock themselves out (though the legitimate owner also cannot be locked out).
**Proof of Concept**:
1. Attacker obtains the owner's private key.
2. Attacker calls `withdraw()` to drain all ETH in the contract.
3. Attacker calls `setHook(maliciousContract)` where every function reverts, bricking all future subscriptions.
4. Attacker calls `transferOwnership(attackerAddress)` then `acceptOwnership()` from the attacker address, completing the two-step transfer.
**Recommendation**: Use a multisig (e.g., Gnosis Safe) as the owner address. Document this as a deployment requirement. Consider separating withdrawal capability from parameter-setting capability by introducing a distinct `withdrawer` role:
```solidity
address public withdrawer;

function withdraw() external {
    require(msg.sender == owner() || msg.sender == withdrawer, "Unauthorized");
    // ...
}
```

## [AC-4] DiscountHook and EvmNowSupporterHook Lack Access Control on onSubscribe/onRelease
**Severity**: Low
**Category**: evm-audit-access-control
**Location**: `onSubscribe()` at DiscountHook.sol:44, `onRelease()` at DiscountHook.sol:45 (inherited by EvmNowSupporterHook)
**Description**: The `onSubscribe()` and `onRelease()` functions in `DiscountHook` (and by extension `EvmNowSupporterHook`) are `external` with no access control. Anyone can call them. In the current implementation, these are empty no-ops, so there is no direct exploit. However, this is inconsistent with `MaxSlotsHook` which correctly enforces `onlySupport` on both functions (MaxSlotsHook.sol:47, 72). If `DiscountHook` is ever extended to track state in these callbacks (e.g., counting active subscribers for volume discounts), the missing access control would become exploitable.
**Proof of Concept**:
1. Deploy `DiscountHook` and set it as the hook on `Support`.
2. Any external address can call `discountHook.onSubscribe(tier, anyAddress)` and `discountHook.onRelease(tier, anyAddress)`.
3. Currently no harm because functions are empty, but this is a latent vulnerability.
**Recommendation**: Add an `onlySupport` modifier to `DiscountHook`, matching the pattern in `MaxSlotsHook`:
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

## [AC-5] SupportRenderer and DiscountHook Use Single-Step Ownable Instead of Ownable2Step
**Severity**: Low
**Category**: evm-audit-access-control
**Location**: SupportRenderer.sol:12, DiscountHook.sol:9
**Description**: `SupportRenderer` inherits `Ownable` (line 12) and `DiscountHook` inherits `Ownable` (line 9). Neither uses `Ownable2Step`. This means a `transferOwnership()` call with a wrong address will permanently lock out the owner of these contracts. The main `Support` contract correctly uses `Ownable2Step` (Support.sol:4, 25), creating an inconsistency in the ownership safety model across the protocol. While these peripheral contracts hold no ETH, losing ownership of `SupportRenderer` means badge configuration (`setTierBadge`) is permanently locked, and losing ownership of `DiscountHook` means discount parameters (`setDiscount`) cannot be changed.
**Proof of Concept**:
1. Owner of `SupportRenderer` calls `transferOwnership(wrongAddress)`.
2. Ownership is immediately transferred. There is no `acceptOwnership()` step.
3. `setTierBadge()` is permanently inaccessible.
**Recommendation**: Replace `Ownable` with `Ownable2Step` in both contracts:
```solidity
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract SupportRenderer is ISupportRenderer, Ownable2Step, WithENSReverseLookup {
    constructor() Ownable(msg.sender) {}
    // ...
}
```

## [AC-6] Third-Party Subscription Creation May Cause Unintended Subscription Binding
**Severity**: Low
**Category**: evm-audit-access-control
**Location**: `support()` at Support.sol:112
**Description**: The `support()` function allows any `msg.sender` to create a subscription for any `recipient`. While tier changes are correctly restricted to the recipient or owner (line 118-121), a third party can: (1) create a brand new subscription for someone who never requested one, (2) renew/extend an existing subscription, or (3) in the `WithSupportTokens` context, mint an NFT to a recipient's address. This is by design (documented in the natspec at line 110-111), but it means an unsolicited NFT can be minted to any address. Combined with `OnePerWallet` (which limits each address to one token), a griefing attack could preemptively mint a low-tier subscription to a target address, forcing them to work around an existing subscription they did not request.
**Proof of Concept**:
1. Attacker calls `support(victimAddress, 0, 1)` with the cheapest tier for 1 month.
2. Victim now has a subscription ID and an NFT minted to their address.
3. Due to `OnePerWallet`, the victim cannot receive another token. They are stuck with this subscription.
4. The victim can still call `support()` to upgrade tiers or extend, but they cannot start from a clean slate.
**Recommendation**: This is a design choice and the impact is limited (the victim can still upgrade or let it expire). However, consider documenting this explicitly in the NatSpec and consider whether `subscription[recipient]` being set to a non-zero value for an unsolicited subscription could confuse off-chain systems. If this is undesirable, add a parameter like `bool selfOnly` or require `msg.sender == recipient` for new subscriptions:
```solidity
// Option: restrict new subscriptions to self-subscribe only
if (!active && msg.sender != recipient && msg.sender != owner()) {
    revert InvalidRecipient();
}
```

## [AC-7] SupportRenderer and Hook Constructors Hardcode msg.sender as Owner
**Severity**: Info
**Category**: evm-audit-access-control
**Location**: SupportRenderer.sol:29, DiscountHook.sol:18
**Description**: `SupportRenderer` (line 29: `Ownable(msg.sender)`) and `DiscountHook` (line 18: `Ownable(msg.sender)`) hardcode `msg.sender` as the owner during construction. This means the deployer address automatically becomes the owner. In contrast, `Support.sol` takes an explicit `_initialOwner` parameter (line 82), allowing the owner to be a multisig or a different address from the deployer. If these contracts are deployed by a hot wallet or a deployment script, the deployer must remember to transfer ownership afterward.
**Proof of Concept**: Not exploitable. This is an operational concern for deployment hygiene.
**Recommendation**: Accept an `_initialOwner` parameter in constructors instead of hardcoding `msg.sender`:
```solidity
constructor(address _initialOwner) Ownable(_initialOwner) {}
```

## [AC-8] SupportRenderer, DiscountHook, and EvmNowSupporterHook Do Not Disable renounceOwnership
**Severity**: Low
**Category**: evm-audit-access-control
**Location**: SupportRenderer.sol:12, DiscountHook.sol:9 (inherited by EvmNowSupporterHook.sol:8)
**Description**: The main `Support` contract correctly disables `renounceOwnership()` by overriding it to revert (Support.sol:103-105). However, `SupportRenderer`, `DiscountHook`, and `EvmNowSupporterHook` all inherit plain `Ownable` without overriding `renounceOwnership()`. If the owner accidentally calls `renounceOwnership()` on any of these contracts, ownership is permanently burned. For `SupportRenderer`, this means `setTierBadge()` becomes permanently inaccessible. For `DiscountHook`, `setDiscount()` becomes permanently inaccessible. For `MaxSlotsHook`, `setMaxSlots()` becomes inaccessible.
**Proof of Concept**:
1. Owner of `DiscountHook` calls `renounceOwnership()`.
2. `owner()` returns `address(0)`.
3. `setDiscount()` is permanently locked; discount parameters can never be changed.
**Recommendation**: Override `renounceOwnership()` to revert in all ownable contracts:
```solidity
function renounceOwnership() public pure override {
    revert();
}
```

## [AC-9] No Deployment Scripts in Audit Scope
**Severity**: Info
**Category**: evm-audit-access-control
**Location**: Project root (missing `deploy/` directory)
**Description**: No deployment scripts were found. Deployment parameter values, role assignments, and the ordering of contract deployments (e.g., deploying `MaxSlotsHook` with the correct `support` address, setting the hook on `Support`, transferring ownership to a multisig) are as security-critical as runtime code. Without auditable deployment scripts, there is no way to verify that the contracts will be deployed correctly.
**Proof of Concept**: Not exploitable. This is a process/documentation gap.
**Recommendation**: Include deployment scripts (e.g., Hardhat Ignition modules or deploy scripts) in the audit scope. At minimum, document the deployment order and expected parameter values:
1. Deploy `SupportToken` with the correct `_initialOwner` (multisig), `_priceFeed`, `_tierPrices`, `_saleStart`, `_logo`, and `_renderer`.
2. Deploy hook contracts with `support` address.
3. Call `setHook()` on `SupportToken`.
4. Transfer ownership of hook and renderer to multisig if needed.

## [AC-10] MaxSlotsHook Owner Is Independent from Support Owner
**Severity**: Info
**Category**: evm-audit-access-control
**Location**: MaxSlotsHook.sol:28, `setMaxSlots()` at MaxSlotsHook.sol:92
**Description**: `MaxSlotsHook` has its own `Ownable` ownership (set to `msg.sender` in constructor, line 28). The `setMaxSlots()` function (line 92) is gated by `onlyOwner`, but this owner is independent from the `Support` contract's owner. If the `Support` owner and `MaxSlotsHook` owner are different entities, the `Support` owner cannot adjust slot limits, and the `MaxSlotsHook` owner can unilaterally change limits that affect the `Support` contract's behavior. This is a trust model nuance: the `Support` owner trusts whoever controls the hook.
**Proof of Concept**: Not directly exploitable. The `Support` owner can always call `setHook(address(0))` to remove the hook if the hook owner becomes adversarial.
**Recommendation**: Document the trust relationships between contract owners. Consider having the `Support` owner also be the owner of all hook contracts, or accept `_initialOwner` as a constructor parameter for `MaxSlotsHook`:
```solidity
constructor(address _support, address _initialOwner) Ownable(_initialOwner) {
    support = _support;
}
```

## [AC-11] Withdraw Sends Funds Only to Owner with No Configurable Recipient
**Severity**: Info
**Category**: evm-audit-access-control
**Location**: `withdraw()` at Support.sol:239-245
**Description**: The `withdraw()` function sends all ETH to `owner()` (line 242). There is no way to configure a different recipient (e.g., a treasury, revenue-splitting contract, or DAO). If the owner is a multisig or smart contract that cannot receive ETH (missing `receive()` function), withdrawals will permanently fail. Combined with `renounceOwnership()` being disabled, this creates a scenario where funds could be trapped if the owner address cannot accept ETH.
**Proof of Concept**:
1. Set owner to a smart contract without a `receive()` or `fallback()` function.
2. Users call `support()` and ETH accumulates in the contract.
3. Owner calls `withdraw()` which sends ETH to the owner contract.
4. The low-level call fails, `sent` is `false`, and `TransferFailed` is reverted.
5. ETH is permanently locked in the `Support` contract.
**Recommendation**: Add a configurable withdrawal recipient, or at minimum, allow the owner to specify a recipient:
```solidity
function withdraw(address to) external onlyOwner {
    if (to == address(0)) to = owner();
    uint256 balance = address(this).balance;
    if (balance == 0) revert NothingToWithdraw();
    (bool sent, ) = to.call{value: balance}("");
    if (!sent) revert TransferFailed();
    emit Withdrawal(to, balance);
}
```
