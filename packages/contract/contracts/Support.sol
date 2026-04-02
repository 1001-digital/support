// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {HasPriceFeed, AggregatorV3Interface} from "@1001-digital/erc721-extensions/contracts/HasPriceFeed.sol";
import {WithSaleStart} from "@1001-digital/erc721-extensions/contracts/WithSaleStart.sol";
import {TierPeriod} from "./interfaces/Types.sol";
import {ISubscriptionHook} from "./interfaces/ISubscriptionHook.sol";

/**
*        ·       ·   ·     ·
*          ·   ·       · ·
*            · · · · · ·
*             · · · · ·
*              ·······
*               ─────
*             ─────────
*           ─────────────
*        ───────────────────
*
*  @title  Support
*  @author yougogirl.eth & jalil.eth
*  @notice A tiered support system on the world computer.
*/
abstract contract Support is Ownable2Step, HasPriceFeed, WithSaleStart {

    // --- Errors ---

    error InvalidTier();
    error InvalidDuration();
    error InvalidRecipient();
    error InsufficientPayment();
    error TransferFailed();
    error NothingToWithdraw();
    error TierChangeForbidden();
    error InvalidPrice();

    // --- Events ---

    event Supported(
        address indexed supporter,
        uint8 indexed tier,
        uint256 indexed subscriptionId,
        uint32 duration,
        uint256 paid,
        uint64 startedAt,
        uint64 expiresAt
    );

    event TierPriceUpdated(uint8 indexed tier, uint128 priceUSD);
    event HookUpdated(address hook);
    event Withdrawal(address indexed to, uint256 amount);

    // --- Constants ---

    uint8 internal constant NO_TIER = type(uint8).max;

    // --- State ---

    // Pricing
    uint128[] public tierPrices;

    // Hook
    ISubscriptionHook public hook;

    // Subscription counter
    uint256 internal _subscriptionIdCounter;

    function totalSupply() public view virtual returns (uint256) {
        return _subscriptionIdCounter;
    }

    // Subscriptions
    mapping(address => uint256) public subscription;
    mapping(uint256 => uint64) public startedAt;
    mapping(uint256 => uint64) public expiresAt;
    mapping(uint256 => TierPeriod[]) public tierHistory;

    // --- Constructor ---

    constructor(
        address _initialOwner,
        address _priceFeed,
        uint128[] memory _tierPrices,
        uint256 _saleStart
    ) Ownable(_initialOwner) HasPriceFeed(_priceFeed) WithSaleStart(_saleStart) {
        for (uint256 i = 0; i < _tierPrices.length; i++) {
            if (_tierPrices[i] == 0) revert InvalidPrice();
        }
        tierPrices = _tierPrices;
    }

    // --- Ownership Overrides ---

    function transferOwnership(address newOwner) public override(Ownable2Step, Ownable) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(Ownable2Step, Ownable) {
        Ownable2Step._transferOwnership(newOwner);
    }

    function renounceOwnership() public pure override {
        revert();
    }

    // --- Public ---

    /// @notice Subscribe an address at a given tier for a number of months.
    /// @dev Third parties can extend or start subscriptions, but only the
    ///      recipient (or owner) may change tiers.
    function support(address recipient, uint8 tier, uint32 duration) external payable afterSaleStart {
        if (recipient == address(0)) revert InvalidRecipient();
        if (tier >= tierPrices.length) revert InvalidTier();

        (uint256 subId, bool active, uint8 previousTier) = _resolveSubscription(recipient);

        if (active && tier != previousTier
            && msg.sender != recipient && msg.sender != owner()) {
            revert TierChangeForbidden();
        }

        // New/reactivated subscriptions require duration >= 1. Active tier changes allow 0.
        if (duration == 0 && (!active || tier == previousTier)) revert InvalidDuration();

        // --- Hook: before ---
        ISubscriptionHook h = hook;
        ISubscriptionHook.Adjustments memory adj = _beforeSubscribe(
            h, tier, duration, recipient, !active, previousTier
        );

        uint256 required;
        uint64 newExpiry;
        uint64 start = uint64(block.timestamp);

        if (!active) {
            required = _baseCost(adj.adjustedUSD);
            if (adj.adjustedStart != 0) start = adj.adjustedStart;
            newExpiry = _addDuration(start, adj.adjustedDuration);
        } else if (tier == previousTier) {
            required = _baseCost(adj.adjustedUSD);
            newExpiry = _addDuration(expiresAt[subId], adj.adjustedDuration);
        } else {
            (required, newExpiry) = _changeTier(expiresAt[subId], previousTier, tier, adj);
        }

        if (msg.value < required) revert InsufficientPayment();

        subId = _applySubscription(recipient, subId, tier, newExpiry, start);
        _notifyHook(h, previousTier, tier, recipient);
        _afterSubscriptionChange(subId);
        emit Supported(recipient, tier, subId, duration, required, startedAt[subId], newExpiry);

        uint256 excess = msg.value - required;
        if (excess > 0) {
            (bool sent, ) = msg.sender.call{value: excess}("");
            if (!sent) revert TransferFailed();
        }
    }

    /// @notice Grant a free subscription (owner only).
    function grant(address recipient, uint8 tier, uint32 duration, uint64 startAt) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();
        if (tier >= tierPrices.length) revert InvalidTier();

        (uint256 subId, bool active, uint8 previousTier) = _resolveSubscription(recipient);

        if (!active && duration == 0) revert InvalidDuration();

        uint64 start = startAt != 0 ? startAt : uint64(block.timestamp);
        uint64 base = active ? expiresAt[subId] : start;
        uint64 newExpiry = _addDuration(base, duration);

        subId = _applySubscription(recipient, subId, tier, newExpiry, start);
        _notifyHook(hook, previousTier, tier, recipient);
        _afterSubscriptionChange(subId);
        emit Supported(recipient, tier, subId, duration, 0, startedAt[subId], newExpiry);
    }

    /// @notice Get cost and adjusted duration for a tier and duration.
    function estimate(uint8 tier, uint32 duration, address supporter) external view returns (uint256 ethCost, uint32 adjustedDuration) {
        if (tier >= tierPrices.length) revert InvalidTier();
        if (duration == 0) revert InvalidDuration();
        (, bool active, uint8 previousTier) = _resolveSubscription(supporter);
        ISubscriptionHook.Adjustments memory adj = _beforeSubscribe(
            hook, tier, duration, supporter, !active, previousTier
        );
        ethCost = _baseCost(adj.adjustedUSD);
        adjustedDuration = adj.adjustedDuration;
    }

    /// @notice Get all tier periods of a subscription.
    function tierPeriods(uint256 subscriptionId) external view returns (TierPeriod[] memory) {
        return tierHistory[subscriptionId];
    }

    /// @notice Get the current tier for a subscription.
    function currentTier(uint256 subscriptionId) public view returns (uint8, bool) {
        if (!_isSubscriptionActive(subscriptionId)) return (0, false);
        return (_lastTier(subscriptionId), true);
    }

    /// @notice Check whether a subscriber's subscription is currently active.
    function isActive(address supporter) public view returns (bool) {
        return _isSubscriptionActive(subscription[supporter]);
    }

    /// @notice Get the number of available tiers.
    function totalTiers() public view returns (uint256) {
        return tierPrices.length;
    }

    // --- Owner ---

    /// @notice Update a tier's monthly USD price.
    function setTierPrice(uint8 tier, uint128 priceUSD) external onlyOwner {
        if (tier >= tierPrices.length) revert InvalidTier();
        if (priceUSD == 0) revert InvalidPrice();
        tierPrices[tier] = priceUSD;
        emit TierPriceUpdated(tier, priceUSD);
    }

    /// @notice Add a new tier with a monthly USD price.
    function addTier(uint128 priceUSD) external onlyOwner {
        if (priceUSD == 0) revert InvalidPrice();
        tierPrices.push(priceUSD);
        emit TierPriceUpdated(uint8(tierPrices.length - 1), priceUSD);
    }

    /// @notice Set the subscription hook contract (address(0) to disable).
    function setHook(ISubscriptionHook _hook) external onlyOwner {
        hook = _hook;
        emit HookUpdated(address(_hook));
    }

    /// @notice Withdraw all collected ETH.
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToWithdraw();
        (bool sent, ) = owner().call{value: balance}("");
        if (!sent) revert TransferFailed();
        emit Withdrawal(owner(), balance);
    }

    // --- Hooks ---

    /// @dev Called when a new subscription is created. Override to add side effects (e.g. minting an NFT).
    function _onNewSubscription(address recipient, uint256 subscriptionId) internal virtual {}

    /// @dev Called after any subscription change. Override to add side effects (e.g. metadata update events).
    function _afterSubscriptionChange(uint256 subscriptionId) internal virtual {}

    // --- Subscription Internals ---

    /// @dev Resolve the supporter's subscription state.
    function _resolveSubscription(address supporter) internal view returns (
        uint256 subscriptionId, bool active, uint8 previousTier
    ) {
        if (supporter == address(0)) return (0, false, NO_TIER);
        subscriptionId = subscription[supporter];
        active = _isSubscriptionActive(subscriptionId);
        previousTier = subscriptionId != 0 ? _lastTier(subscriptionId) : NO_TIER;
    }

    /// @dev Notify the hook of a tier change.
    function _notifyHook(ISubscriptionHook h, uint8 previousTier, uint8 tier, address recipient) internal {
        if (address(h) == address(0)) return;
        if (previousTier != NO_TIER && previousTier != tier) {
            h.onRelease(previousTier, recipient);
        }
        h.onSubscribe(tier, recipient);
    }

    function _changeTier(
        uint64 currentExpiry, uint8 fromTier, uint8 toTier,
        ISubscriptionHook.Adjustments memory adj
    ) private view returns (uint256 required, uint64 newExpiry) {
        uint64 remaining = currentExpiry - uint64(block.timestamp);
        uint128 oldPrice = tierPrices[fromTier];
        uint128 newPrice = tierPrices[toTier];

        required = _baseCost(adj.adjustedUSD);

        uint256 converted = uint256(remaining) * oldPrice / newPrice;
        uint256 rawExpiry = uint256(block.timestamp) + converted + uint256(adj.adjustedDuration) * 30 days;

        // Upgrading must result in at least 30 days from now.
        if (newPrice > oldPrice) {
            uint256 minExpiry = uint256(block.timestamp) + 30 days;
            if (rawExpiry < minExpiry) {
                required += _baseCost(uint256(newPrice) * (minExpiry - rawExpiry) / 30 days);
                rawExpiry = minExpiry;
            }
        }

        newExpiry = rawExpiry > type(uint64).max ? type(uint64).max : uint64(rawExpiry);
    }

    function _applySubscription(
        address recipient, uint256 subscriptionId, uint8 tier, uint64 newExpiry, uint64 start
    ) internal returns (uint256) {
        if (subscriptionId == 0) {
            subscriptionId = ++_subscriptionIdCounter;
            _onNewSubscription(recipient, subscriptionId);
        }

        if (block.timestamp >= expiresAt[subscriptionId]) {
            // New or reactivated — reset
            startedAt[subscriptionId] = start;
            delete tierHistory[subscriptionId];
            tierHistory[subscriptionId].push(TierPeriod(tier, start));
        } else if (tier != _lastTier(subscriptionId)) {
            tierHistory[subscriptionId].push(TierPeriod(tier, uint64(block.timestamp)));
        }

        subscription[recipient] = subscriptionId;
        expiresAt[subscriptionId] = newExpiry;
        return subscriptionId;
    }

    /// @dev Safely add duration months to a base timestamp, capping at uint64 max.
    function _addDuration(uint64 base, uint32 duration) internal pure returns (uint64) {
        uint256 result = uint256(base) + uint256(duration) * 30 days;
        return result > type(uint64).max ? type(uint64).max : uint64(result);
    }

    // --- Subscription helpers ---

    function _isSubscriptionActive(uint256 subId) internal view returns (bool) {
        return subId != 0 && block.timestamp < expiresAt[subId] && startedAt[subId] <= block.timestamp;
    }

    function _lastTier(uint256 subscriptionId) internal view returns (uint8) {
        TierPeriod[] storage periods = tierHistory[subscriptionId];
        return periods[periods.length - 1].tier;
    }

    // --- Pricing ---

    function _beforeSubscribe(
        ISubscriptionHook h, uint8 tier, uint32 duration, address supporter, bool isNew, uint8 previousTier
    ) internal view returns (ISubscriptionHook.Adjustments memory adj) {
        uint256 baseUSD = uint256(tierPrices[tier]) * duration;
        if (address(h) == address(0)) {
            return ISubscriptionHook.Adjustments(baseUSD, duration, 0);
        }
        adj = h.beforeSubscribe(tier, duration, baseUSD, supporter, isNew, previousTier);
    }

    function _baseCost(uint256 adjustedUSD) internal view returns (uint256) {
        if (adjustedUSD == 0) return 0;
        return _usdToEth(adjustedUSD);
    }

}
