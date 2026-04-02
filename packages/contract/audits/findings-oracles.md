# Oracle & Pricing Security Audit Findings

**Scope**: Support.sol, SupportToken.sol, WithSupportTokens.sol, HasPriceFeed.sol (dependency), and associated hooks/interfaces.

**Auditor**: Claude (evm-audit-oracles checklist)

**Date**: 2026-04-02

---

## Checklist Walkthrough

The contracts use a single Chainlink ETH/USD price feed (via the `HasPriceFeed` abstract contract from `@1001-digital/erc721-extensions`) to convert USD-denominated tier prices into ETH amounts. The core conversion happens in `_usdToEth()` at `HasPriceFeed.sol:35-41`, which is called by `_baseCost()` at `Support.sol:348-351`.

### Items that apply and have findings:

1. **Staleness & Liveness** -- Partial checks present, but missing `startedAt == 0` check. See [O-1].
2. **Answer Bounds (minAnswer/maxAnswer)** -- No circuit breaker check. See [O-2].
3. **L2 Sequencer Uptime** -- Not applicable currently (hardhat config shows L1 mainnet/sepolia deployment), but no protection if deployed to L2. See [O-3].
4. **Feed Decimals** -- Hardcoded assumption of 8 decimals. See [O-4].
5. **Single Oracle Dependency** -- No fallback oracle. See [O-5].
6. **Hardcoded Staleness Threshold** -- 1 hour hardcoded, problematic for multi-chain. See [O-6].
7. **Unhandled Oracle Revert / DoS** -- No try/catch. See [O-7].

### Items that apply and have NO issues:

- **Negative prices**: `HasPriceFeed.sol:38` checks `price <= 0`, which correctly rejects both zero and negative prices.
- **Price = 0**: Same check covers this case.
- **`answeredInRound < roundId`**: `HasPriceFeed.sol:39` correctly checks `answeredInRound < roundId`.
- **`updatedAt` staleness**: `HasPriceFeed.sol:40` checks `block.timestamp - updatedAt > _maxStaleness()`.
- **Deprecated feeds**: `setPriceFeed()` at `HasPriceFeed.sol:27-31` allows the owner to update the price feed address. This mitigates the deprecated feed risk.
- **Price peg assumptions**: The protocol only uses ETH/USD pricing for native ETH payments. No WBTC, stETH, or stablecoin peg assumptions.
- **Spot price manipulation**: Not applicable -- the protocol uses Chainlink, not AMM spot prices.
- **TWAP oracles**: Not used.
- **Pyth Network**: Not used.
- **Read-only reentrancy on Balancer/Curve**: Not applicable.
- **Multi-hop price derivation**: Not applicable -- single ETH/USD feed.
- **Oracle front-running**: Low impact here because the protocol is a subscription system, not a lending/trading protocol. The worst case is a user paying slightly more/less ETH for a fixed USD subscription. The economic incentive to front-run is minimal.

---

## [O-1] Missing `startedAt == 0` validation on Chainlink round data

**Severity**: Low

**Category**: evm-audit-oracles

**Location**: `_usdToEth()` in `HasPriceFeed.sol:36-41`

**Description**: The `_usdToEth()` function calls `priceFeed.latestRoundData()` and validates `price <= 0`, `answeredInRound < roundId`, and staleness via `updatedAt`. However, it does not check whether `startedAt == 0`. A `startedAt` value of zero indicates the round has not actually started and no valid price update has occurred for this round. While this is an edge case (Chainlink would typically not return `startedAt == 0` in production), it is a best-practice validation that other checks may not fully cover.

The current code at `HasPriceFeed.sol:36-40`:
```solidity
(uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound)
    = priceFeed.latestRoundData();
if (price <= 0) revert StalePrice();
if (answeredInRound < roundId) revert StalePrice();
if (block.timestamp - updatedAt > _maxStaleness()) revert StalePrice();
```

Note that the `startedAt` return value (third positional) is explicitly discarded with `,`.

**Proof of Concept**: If Chainlink returns a round where `startedAt == 0` but `price > 0` and `answeredInRound >= roundId` and `updatedAt` is recent, the function would accept this potentially invalid round data. This is a theoretical edge case.

**Recommendation**: Capture and validate `startedAt`:
```solidity
(uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    = priceFeed.latestRoundData();
if (price <= 0) revert StalePrice();
if (startedAt == 0) revert StalePrice();
if (answeredInRound < roundId) revert StalePrice();
if (block.timestamp - updatedAt > _maxStaleness()) revert StalePrice();
```

---

## [O-2] No Chainlink `minAnswer`/`maxAnswer` circuit breaker check

**Severity**: Medium

**Category**: evm-audit-oracles

**Location**: `_usdToEth()` in `HasPriceFeed.sol:35-41`

**Description**: Chainlink price feeds have hardcoded `minAnswer` and `maxAnswer` bounds in their aggregator contracts. During extreme market events (flash crashes or parabolic pumps), if the real ETH price moves beyond these bounds, the feed will report the bound value instead of the actual price.

For example, if ETH crashes to $50 but the feed's `minAnswer` corresponds to $100, Chainlink would still report $100. In this protocol, the `_usdToEth()` conversion at line 41 would then compute a subscription cost based on $100/ETH instead of $50/ETH, meaning subscribers pay roughly half of what they should in ETH terms. Conversely, if ETH moons past the `maxAnswer`, the feed caps the price, and subscribers would overpay in ETH.

While this is a subscription protocol (not a lending protocol where this could lead to direct fund theft), it still causes incorrect pricing that could result in the owner receiving substantially less ETH value than intended for subscriptions.

**Proof of Concept**:
1. ETH price crashes from $2000 to $50 (extreme but not unprecedented -- LUNA-style event).
2. Chainlink feed reports `minAnswer` (e.g., equivalent to $100) instead of $50.
3. A user calls `support()` for a $10/month tier.
4. `_usdToEth(1000000000)` computes `1000000000 * 1e18 / 10000000000 = 0.1 ETH` (at $100).
5. The actual value of 0.1 ETH at $50 is only $5, not $10. The protocol receives half the intended USD value.

**Recommendation**: Read the aggregator's `minAnswer` and `maxAnswer` and validate:
```solidity
// Cache the aggregator reference
IChainlinkAggregator aggregator = IChainlinkAggregator(address(priceFeed));
int192 minAnswer = aggregator.minAnswer();
int192 maxAnswer = aggregator.maxAnswer();
require(price > minAnswer && price < maxAnswer, "Circuit breaker triggered");
```
Alternatively, since the `AggregatorV3Interface` defined in `HasPriceFeed.sol:50-58` is minimal and does not expose `minAnswer()`/`maxAnswer()`, the owner could monitor off-chain and pause the contract or swap the feed if circuit breakers are hit.

---

## [O-3] No L2 sequencer uptime check for potential L2 deployment

**Severity**: Low

**Category**: evm-audit-oracles

**Location**: `_usdToEth()` in `HasPriceFeed.sol:35-41` and `hardhat.config.ts`

**Description**: The current `hardhat.config.ts` only defines L1 networks (`mainnet`, `sepolia`), so the protocol appears to target Ethereum mainnet. However, there is no on-chain enforcement preventing deployment to an L2 (Arbitrum, Optimism, Base, etc.), and the `HasPriceFeed` contract has no L2 sequencer uptime check.

If deployed on an L2 where the sequencer goes down, Chainlink price feeds stop updating. When the sequencer restarts, the first `latestRoundData()` call may return a stale price from before the outage. Users could subscribe at an outdated ETH/USD price, potentially paying significantly less (or more) than intended.

The 1-hour staleness check in `_maxStaleness()` would catch some cases, but on L2s like Arbitrum, the ETH/USD feed has a 24-hour heartbeat, meaning a 1-hour staleness threshold would cause constant reverts under normal operation (see [O-6]).

**Proof of Concept**: Not currently exploitable since the protocol targets L1. This is a latent risk if the protocol is deployed to L2s in the future without modification.

**Recommendation**: If L2 deployment is planned, add a sequencer uptime feed check with a grace period:
```solidity
AggregatorV3Interface sequencerFeed = AggregatorV3Interface(SEQUENCER_UPTIME_FEED);
(, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();
if (answer != 0) revert SequencerDown();
if (block.timestamp - startedAt < GRACE_PERIOD) revert GracePeriodNotOver();
```

---

## [O-4] Hardcoded 8-decimal assumption for price feed

**Severity**: Low

**Category**: evm-audit-oracles

**Location**: `_usdToEth()` in `HasPriceFeed.sol:41` and tier price definitions in `Support.sol:61`

**Description**: The `_usdToEth()` function at `HasPriceFeed.sol:41` performs:
```solidity
return usdAmount * 1e18 / uint256(price);
```

This implicitly assumes the price feed returns 8-decimal values (which is correct for Chainlink ETH/USD). The tier prices are also stored in 8-decimal format (e.g., `500000000` = $5.00 in the test file at `test/Support.ts:14`).

The NatSpec comment at `HasPriceFeed.sol:33-34` states: "The `usdAmount` must use the same decimal precision as the price feed (8 decimals for Chainlink ETH/USD)." While this is documented, the code does not call `priceFeed.decimals()` to dynamically determine the feed's precision. If `setPriceFeed()` is called with a feed that uses different decimals (e.g., 18 decimals as some feeds do), the conversion would be off by a factor of 10^10, causing subscriptions to cost 10 billion times too little or too much ETH.

The `setPriceFeed()` function at `HasPriceFeed.sol:27-31` only validates `_priceFeed != address(0)` -- it does not verify the new feed uses 8 decimals.

**Proof of Concept**:
1. Owner calls `setPriceFeed()` with a feed that uses 18 decimals.
2. Feed returns `price = 2000 * 1e18 = 2000000000000000000000`.
3. `_usdToEth(500000000)` computes `500000000 * 1e18 / 2000000000000000000000 = 250000000000000` wei = 0.00025 ETH instead of the intended 0.0025 ETH.
4. Subscribers pay 10x less than intended.

**Recommendation**: Either query `priceFeed.decimals()` and normalize dynamically, or add a decimals check in `setPriceFeed()`:
```solidity
function setPriceFeed(address _priceFeed) public virtual onlyOwner {
    if (_priceFeed == address(0)) revert InvalidPriceFeed();
    AggregatorV3Interface feed = AggregatorV3Interface(_priceFeed);
    // Optionally: require(feed.decimals() == 8, "Unexpected decimals");
    priceFeed = feed;
    emit PriceFeedUpdated(_priceFeed);
}
```

Or normalize dynamically:
```solidity
function _usdToEth(uint256 usdAmount) internal view virtual returns (uint256) {
    // ... staleness checks ...
    uint8 decimals = priceFeed.decimals();
    return usdAmount * 1e18 / uint256(price) * 10**8 / 10**decimals;
}
```

Note: The `AggregatorV3Interface` defined in `HasPriceFeed.sol:50-58` does not include a `decimals()` function. It would need to be extended.

---

## [O-5] Single oracle dependency with no fallback

**Severity**: Low

**Category**: evm-audit-oracles

**Location**: `_usdToEth()` in `HasPriceFeed.sol:35-41`, `_baseCost()` in `Support.sol:348-351`

**Description**: The entire pricing mechanism depends on a single Chainlink price feed. If this feed is deprecated, access-restricted (Chainlink multisigs can block access), or consistently stale, all calls to `support()` and `estimate()` will revert, causing a complete denial of service for new subscriptions and renewals.

The `_usdToEth()` function reverts on stale price (`StalePrice` error) but provides no fallback mechanism. This means:
- `support()` at `Support.sol:112` will revert (via `_baseCost()` -> `_usdToEth()`)
- `estimate()` at `Support.sol:181` will revert
- Only `grant()` at `Support.sol:162` would still work since it does not call `_baseCost()`

The `setPriceFeed()` function allows the owner to update the feed address, which is a good mitigation, but it cannot be called atomically when the feed goes down -- there is an unavoidable downtime window.

**Proof of Concept**:
1. Chainlink deprecates or access-restricts the configured ETH/USD feed.
2. `priceFeed.latestRoundData()` reverts.
3. All `support()` calls revert.
4. No new paid subscriptions can be created until the owner calls `setPriceFeed()` with a new valid feed.
5. Depending on the owner's response time, this could be hours of downtime.

**Recommendation**: For a subscription protocol, the impact is limited (users cannot subscribe temporarily but no funds are at risk). The existing `setPriceFeed()` function provides adequate mitigation for this use case. For added resilience, consider wrapping the Chainlink call in a try/catch with a cached fallback price (see [O-7]).

---

## [O-6] Hardcoded 1-hour staleness threshold may be too strict or too lenient depending on chain

**Severity**: Low

**Category**: evm-audit-oracles

**Location**: `_maxStaleness()` in `HasPriceFeed.sol:45-47`

**Description**: The `_maxStaleness()` function returns a hardcoded `1 hours` (3600 seconds). The Chainlink ETH/USD feed on Ethereum mainnet has a 1-hour heartbeat, so this is correct for mainnet. However:

1. On Arbitrum, the ETH/USD feed has a ~24-hour heartbeat with a 0.5% deviation threshold. A 1-hour staleness check would cause constant `StalePrice` reverts during periods of low volatility where the price doesn't move 0.5% within an hour.
2. On some L2s, feed update frequency varies. A single hardcoded value cannot be correct across chains.

The function is declared `virtual`, so it can be overridden by child contracts, which is good. But the current concrete deployment (`SupportToken.sol`) does not override it.

**Proof of Concept**: If the same `SupportToken` contract is deployed on Arbitrum without overriding `_maxStaleness()`:
1. ETH price is stable, so Chainlink only updates every ~24 hours on Arbitrum.
2. After 1 hour without an update, `block.timestamp - updatedAt > 3600` becomes true.
3. Every `support()` call reverts with `StalePrice()`.
4. The protocol is DoS'd until the next Chainlink update.

**Recommendation**: Since `_maxStaleness()` is already virtual, this is well-designed for L1. For multi-chain deployment, override `_maxStaleness()` per-chain or make it a configurable storage variable:
```solidity
uint256 public maxStaleness = 1 hours;

function setMaxStaleness(uint256 _maxStaleness) external onlyOwner {
    require(_maxStaleness > 0 && _maxStaleness <= 24 hours, "Invalid staleness");
    maxStaleness = _maxStaleness;
}

function _maxStaleness() internal view override returns (uint256) {
    return maxStaleness;
}
```

---

## [O-7] Unhandled Chainlink revert causes complete subscription DoS

**Severity**: Medium

**Category**: evm-audit-oracles

**Location**: `_usdToEth()` in `HasPriceFeed.sol:36-37`, `_baseCost()` in `Support.sol:348-351`

**Description**: The call to `priceFeed.latestRoundData()` at `HasPriceFeed.sol:36-37` is not wrapped in a `try/catch`. Chainlink multisigs have the ability to block access to price feeds, and feeds can also revert during contract migrations or when deprecated. If `latestRoundData()` reverts, the entire `_usdToEth()` call reverts, which propagates up through `_baseCost()` to `support()` and `estimate()`.

This means a Chainlink-side revert (not a stale price, but an actual revert of the external call) will brick all paid subscription functionality with no graceful degradation.

While `setPriceFeed()` allows the owner to swap to a different feed, there is no way to use the protocol during the window between the feed going down and the owner's corrective action.

**Proof of Concept**:
1. Chainlink access-controls the ETH/USD feed (they have done this before -- see Code4rena Inverse Finance finding).
2. `priceFeed.latestRoundData()` reverts with access denied.
3. `_usdToEth()` reverts.
4. `_baseCost()` reverts.
5. `support()` reverts for all users.
6. `estimate()` also reverts, so the frontend cannot even show prices.

**Recommendation**: Wrap the Chainlink call in try/catch and maintain a cached last-known-good price:
```solidity
uint256 private _cachedPrice;
uint256 private _cachedAt;

function _usdToEth(uint256 usdAmount) internal view virtual returns (uint256) {
    try priceFeed.latestRoundData() returns (
        uint80 roundId, int256 price, uint256, uint256 updatedAt, uint80 answeredInRound
    ) {
        if (price <= 0) revert StalePrice();
        if (answeredInRound < roundId) revert StalePrice();
        if (block.timestamp - updatedAt > _maxStaleness()) revert StalePrice();
        _cachedPrice = uint256(price);
        _cachedAt = block.timestamp;
        return usdAmount * 1e18 / uint256(price);
    } catch {
        // Fall back to cached price if recent enough
        if (_cachedPrice > 0 && block.timestamp - _cachedAt <= _maxStaleness() * 2) {
            return usdAmount * 1e18 / _cachedPrice;
        }
        revert StalePrice();
    }
}
```

Alternatively, for a simpler approach given this is a subscription protocol (not a lending protocol), accept the DoS risk and rely on `setPriceFeed()` for recovery. Document this as a known limitation.

---

## Summary

| ID | Title | Severity |
|----|-------|----------|
| O-1 | Missing `startedAt == 0` validation on Chainlink round data | Low |
| O-2 | No Chainlink `minAnswer`/`maxAnswer` circuit breaker check | Medium |
| O-3 | No L2 sequencer uptime check for potential L2 deployment | Low |
| O-4 | Hardcoded 8-decimal assumption for price feed | Low |
| O-5 | Single oracle dependency with no fallback | Low |
| O-6 | Hardcoded 1-hour staleness threshold may be too strict/lenient per chain | Low |
| O-7 | Unhandled Chainlink revert causes complete subscription DoS | Medium |

### Overall Assessment

The `HasPriceFeed` dependency implements the most critical Chainlink safety checks: `price <= 0`, `answeredInRound < roundId`, and timestamp-based staleness. The `setPriceFeed()` function provides an owner escape hatch for deprecated feeds. The protocol is a subscription system (not a lending/DEX protocol), so the impact of oracle issues is generally limited to incorrect pricing rather than direct fund theft.

The two Medium findings (O-2 and O-7) represent scenarios where the protocol could either misprice subscriptions during extreme market events or become completely unavailable due to Chainlink feed issues. Neither leads to direct loss of user funds, but both degrade the protocol's reliability and could cause economic loss for the owner.

The Low findings are best-practice improvements that strengthen the oracle integration's robustness, particularly for future multi-chain deployment.
