# Oracle & Pricing Security Audit Findings

**Scope**: `Support.sol`, `SupportToken.sol`, `HasPriceFeed.sol`, `DiscountHook.sol`, `MaxSlotsHook.sol`, `ISubscriptionHook.sol`
**Checklist**: `evm-audit-oracles`
**Date**: 2026-04-02

---

## [O-1] Missing `startedAt == 0` validation allows uninitialized round data
**Severity**: Low
**Category**: evm-audit-oracles
**Location**: `_usdToEth()` in `HasPriceFeed.sol:36-41`
**Description**: The `_usdToEth()` function calls `priceFeed.latestRoundData()` and destructures the result, but discards `startedAt` entirely (line 36: `(uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound)`). A round with `startedAt == 0` means the round has not actually started and should be considered invalid. While the existing `answeredInRound < roundId` and staleness checks provide partial protection, they do not cover the edge case of an uninitialized round where `startedAt` is zero but other fields pass validation.
**Proof of Concept**:
1. Chainlink feed enters a state where a new round is initiated but `startedAt` remains 0 (round not yet populated).
2. If `answeredInRound == roundId` and `updatedAt` is within the staleness window (carried from a prior state), the check passes.
3. The contract uses potentially invalid price data for the USD-to-ETH conversion.
**Recommendation**: Add a `startedAt > 0` check in `_usdToEth()`:
```solidity
function _usdToEth(uint256 usdAmount) internal view virtual returns (uint256) {
    (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
        = priceFeed.latestRoundData();
    if (price <= 0) revert StalePrice();
    if (startedAt == 0) revert StalePrice();
    if (answeredInRound < roundId) revert StalePrice();
    if (block.timestamp - updatedAt > _maxStaleness()) revert StalePrice();
    return usdAmount * 1e18 / uint256(price);
}
```

---

## [O-2] No `minAnswer` / `maxAnswer` circuit breaker check
**Severity**: Medium
**Category**: evm-audit-oracles
**Location**: `_usdToEth()` in `HasPriceFeed.sol:35-42`
**Description**: Chainlink aggregator feeds have hard-coded `minAnswer` and `maxAnswer` bounds. When the real market price falls below `minAnswer` (or exceeds `maxAnswer`), the feed clamps to the boundary value instead of reporting the actual price. The `_usdToEth()` function only checks `price <= 0` but does not verify that the returned price is not pinned at a circuit breaker boundary. For the ETH/USD feed, if ETH were to crash below the feed's `minAnswer`, the contract would still use `minAnswer` as the price, making subscriptions cheaper than they should be (users pay less ETH than the real market value of their USD subscription). Conversely, if ETH price exceeds `maxAnswer`, the contract would charge users more ETH than necessary.
**Proof of Concept**:
1. ETH price crashes to $50, but the Chainlink ETH/USD feed has `minAnswer = $100`.
2. The feed reports $100 instead of $50.
3. A user subscribing at $5/month pays 0.05 ETH (at the reported $100 price) instead of 0.1 ETH (at the real $50 price).
4. The project owner receives half the expected ETH value for subscriptions.
**Recommendation**: Query the aggregator's `minAnswer` and `maxAnswer` and validate the returned price is not at the boundary. Override `_usdToEth()` in `Support.sol`:
```solidity
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";

// In _usdToEth override or a wrapper:
IAggregatorV3 aggregator = IAggregatorV3(priceFeed.aggregator());
int192 minAnswer = aggregator.minAnswer();
int192 maxAnswer = aggregator.maxAnswer();
if (price <= minAnswer || price >= maxAnswer) revert StalePrice();
```
Note: The severity is Medium rather than High because the protocol collects subscription fees rather than managing collateral/lending positions, limiting the economic impact to degraded revenue for the project owner.

---

## [O-3] Hardcoded feed decimals assumption (`1e18 / uint256(price)`) assumes 8-decimal feed
**Severity**: Medium
**Category**: evm-audit-oracles
**Location**: `_usdToEth()` in `HasPriceFeed.sol:41`
**Description**: The conversion formula `usdAmount * 1e18 / uint256(price)` implicitly assumes the price feed uses the same decimal precision as the `usdAmount` (which is set via `tierPrices`, using 8 decimals per the test configuration: e.g., `500000000` = $5.00 in 8-decimal format). The Chainlink ETH/USD feed does use 8 decimals, so the math works: `(5 * 1e8) * 1e18 / (2000 * 1e8) = 0.0025e18 = 0.0025 ETH`. However, the contract never calls `priceFeed.decimals()` to verify this assumption. If the price feed is changed (via `setPriceFeed()`) to one with different decimal precision (e.g., 18 decimals), the conversion would be off by a factor of 10^10, resulting in users paying drastically incorrect amounts. The `AggregatorV3Interface` defined in `HasPriceFeed.sol` (lines 50-58) does not even include a `decimals()` function, making it impossible to query.
**Proof of Concept**:
1. Owner calls `setPriceFeed()` with a feed address that returns 18-decimal prices (some specialized feeds do this).
2. ETH/USD at $2000 would be returned as `2000 * 1e18` instead of `2000 * 1e8`.
3. The formula computes `500000000 * 1e18 / (2000 * 1e18) = 250000000` wei = 0.00000000025 ETH for a $5 subscription instead of 0.0025 ETH.
4. Users pay 10 billion times less than intended.
**Recommendation**: Add `decimals()` to the `AggregatorV3Interface` and normalize the price dynamically:
```solidity
interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

function _usdToEth(uint256 usdAmount) internal view virtual returns (uint256) {
    // ... staleness checks ...
    uint8 feedDecimals = priceFeed.decimals();
    return usdAmount * 1e18 / uint256(price) * 10**feedDecimals / 10**8;
    // Or more precisely: normalize usdAmount and price to same base
}
```
Alternatively, validate on `setPriceFeed()` that the new feed uses 8 decimals.

---

## [O-4] Hardcoded 1-hour staleness threshold will fail on L2 deployments
**Severity**: Medium
**Category**: evm-audit-oracles
**Location**: `_maxStaleness()` in `HasPriceFeed.sol:45-47`
**Description**: The `_maxStaleness()` function returns a hardcoded `1 hours` (3600 seconds). While this is appropriate for the Chainlink ETH/USD feed on Ethereum mainnet (which has a 1-hour heartbeat), the same feed on L2 networks like Arbitrum or Base has a 24-hour heartbeat. If the contract is deployed to an L2 without overriding `_maxStaleness()`, every call to `_usdToEth()` will revert with `StalePrice()` after 1 hour from the last feed update, because the feed legitimately only updates every 24 hours (or upon a deviation threshold). The hardhat config currently only defines L1 networks (mainnet, sepolia), but the `Support` contract is `abstract` and designed for reuse, making L2 deployment a realistic future scenario.
**Proof of Concept**:
1. Deploy `SupportToken` on Arbitrum with the Arbitrum ETH/USD Chainlink feed (24h heartbeat).
2. The feed updates at T=0.
3. At T=1h+1s, a user calls `support()`.
4. `_usdToEth()` checks `block.timestamp - updatedAt > 3600` which is true.
5. The call reverts with `StalePrice()`, making the contract unusable for 23 out of every 24 hours.
**Recommendation**: The `_maxStaleness()` function is already `virtual`, which is good. Either:
1. Override it in `Support.sol` to accept a constructor parameter for the staleness threshold, or
2. Add deployment documentation specifying that L2 deployments must override `_maxStaleness()`.
```solidity
// Option 1: Make staleness configurable in Support.sol
uint256 private immutable _stalenessThreshold;

constructor(..., uint256 stalenessThreshold_) {
    _stalenessThreshold = stalenessThreshold_;
}

function _maxStaleness() internal view override returns (uint256) {
    return _stalenessThreshold;
}
```

---

## [O-5] No L2 sequencer uptime check
**Severity**: Medium
**Category**: evm-audit-oracles
**Location**: `_usdToEth()` in `HasPriceFeed.sol:35-42`
**Description**: When deployed on L2 chains (Arbitrum, Optimism, Base), the Chainlink price feed can return stale prices if the L2 sequencer goes down and comes back up. The `_usdToEth()` function does not check the L2 sequencer uptime feed. After a sequencer restart, the price feed may still show the pre-downtime price, which could be significantly different from the current market price. This affects all payment calculations in `Support.sol`. While the hardhat config currently only defines L1 networks, the abstract architecture of `Support.sol` is designed for reuse across chains.
**Proof of Concept**:
1. Deploy on Arbitrum. ETH is at $2000. Sequencer goes down.
2. While sequencer is down, ETH drops to $1500 on other markets.
3. Sequencer comes back online. The Chainlink feed still reports $2000 until oracles update.
4. A user subscribes immediately after sequencer restart. They pay based on $2000 ETH (less ETH) when the real price is $1500 (should pay more ETH).
5. The project owner receives less value than expected.
**Recommendation**: For L2 deployments, integrate a sequencer uptime check with a grace period. Override `_usdToEth()` in an L2-specific subcontract:
```solidity
AggregatorV3Interface internal immutable sequencerUptimeFeed;
uint256 private constant GRACE_PERIOD = 3600; // 1 hour

function _usdToEth(uint256 usdAmount) internal view override returns (uint256) {
    // Check sequencer status
    (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
    bool isSequencerUp = answer == 0;
    if (!isSequencerUp) revert SequencerDown();
    if (block.timestamp - startedAt < GRACE_PERIOD) revert GracePeriodNotOver();

    return super._usdToEth(usdAmount);
}
```

---

## [O-6] Single oracle dependency with no fallback
**Severity**: Low
**Category**: evm-audit-oracles
**Location**: `_usdToEth()` in `HasPriceFeed.sol:35-42`, `_baseCost()` in `Support.sol:366-369`
**Description**: The entire payment system relies on a single Chainlink price feed with no fallback oracle. If the Chainlink feed is deprecated, the multisig blocks access, or it returns invalid data that causes a revert, all subscription operations (`support()`, `cost()`, `estimate()`) become permanently bricked. The `setPriceFeed()` function allows the owner to update the feed address, but if the Chainlink multisig suddenly blocks access to the current feed, users cannot subscribe until the owner executes a governance action to update the feed. The `grant()` function (owner-only free subscriptions) is not affected since it bypasses pricing.
**Proof of Concept**:
1. Chainlink deprecates the current ETH/USD feed or the multisig blocks access.
2. `latestRoundData()` reverts.
3. All calls to `support()`, `cost()`, and `estimate()` revert.
4. Users cannot create or extend subscriptions until the owner calls `setPriceFeed()` with a new feed address.
**Recommendation**: Consider wrapping the `latestRoundData()` call in a try/catch with a fallback mechanism:
```solidity
function _usdToEth(uint256 usdAmount) internal view virtual returns (uint256) {
    try priceFeed.latestRoundData() returns (
        uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    ) {
        if (price <= 0) revert StalePrice();
        if (answeredInRound < roundId) revert StalePrice();
        if (block.timestamp - updatedAt > _maxStaleness()) revert StalePrice();
        return usdAmount * 1e18 / uint256(price);
    } catch {
        // Fallback to secondary oracle or revert with descriptive error
        revert OracleUnavailable();
    }
}
```
The severity is Low because the owner can recover by calling `setPriceFeed()`, and the impact is limited to a temporary DoS of paid subscriptions (grants still work).

---

## [O-7] Unhandled `latestRoundData()` revert causes complete DoS of paid subscriptions
**Severity**: Low
**Category**: evm-audit-oracles
**Location**: `_usdToEth()` in `HasPriceFeed.sol:36-37`, `_baseCost()` in `Support.sol:366-369`
**Description**: The call to `priceFeed.latestRoundData()` is not wrapped in a try/catch. If the Chainlink feed reverts for any reason (deprecated feed, access control changes, feed migration), the raw revert propagates up through `_baseCost()` -> `support()`, causing a complete denial of service for all paid subscription operations. Chainlink multisigs have the ability to block access to price feeds at any time. While this is related to O-6 (single oracle dependency), the specific risk here is that an unhandled revert from an external call bricks the core user-facing function with no graceful degradation.
**Proof of Concept**:
1. Chainlink feed at the stored address begins reverting (access revoked, contract self-destructed, or proxy upgraded to incompatible interface).
2. Every call to `support()` with a non-zero tier price reverts.
3. The `cost()` and `estimate()` view functions also become unusable.
4. Only `grant()` (which does not call `_usdToEth`) continues to work.
**Recommendation**: Wrap the external call in try/catch as shown in O-6. Additionally, consider a circuit breaker pattern where the owner can set a manual ETH price as a fallback when the oracle is unavailable.

---

## [O-8] Price feed address is owner-changeable but lacks validation of feed correctness
**Severity**: Info
**Category**: evm-audit-oracles
**Location**: `setPriceFeed()` in `HasPriceFeed.sol:27-31`
**Description**: The `setPriceFeed()` function allows the owner to update the price feed address to any non-zero address. There is no validation that the new address actually implements `AggregatorV3Interface`, returns a reasonable price, uses the expected decimal precision, or is an ETH/USD feed (vs. BTC/USD or another denomination). A misconfigured feed would silently produce incorrect pricing. The mitigation is that the contract uses `Ownable2Step`, requiring the new owner to explicitly accept, reducing accidental ownership-related misconfiguration. However, the feed address change itself is a single-step operation.
**Proof of Concept**:
1. Owner accidentally calls `setPriceFeed()` with a BTC/USD feed address.
2. BTC/USD returns ~$60,000 in 8 decimals instead of ETH ~$2,000.
3. All subscriptions are now priced as if 1 ETH = $60,000, making them ~30x cheaper in ETH terms.
4. The project receives 30x less ETH value than intended.
**Recommendation**: Add a sanity check when setting the feed:
```solidity
function setPriceFeed(address _priceFeed) public virtual onlyOwner {
    if (_priceFeed == address(0)) revert InvalidPriceFeed();
    AggregatorV3Interface newFeed = AggregatorV3Interface(_priceFeed);
    // Sanity check: feed must return valid data
    (, int256 price,,,) = newFeed.latestRoundData();
    if (price <= 0) revert InvalidPriceFeed();
    priceFeed = newFeed;
    emit PriceFeedUpdated(_priceFeed);
}
```
