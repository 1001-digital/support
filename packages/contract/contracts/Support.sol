// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {HasPriceFeed, AggregatorV3Interface} from "@1001-digital/erc721-extensions/contracts/HasPriceFeed.sol";
import {WithSaleStart} from "@1001-digital/erc721-extensions/contracts/WithSaleStart.sol";
import {TierPeriod} from "./interfaces/ISupportRenderer.sol";
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
*  @author ygg
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
        uint256 indexed tokenId,
        uint32 duration,
        uint256 paid,
        uint64 expiresAt
    );

    event TierPriceUpdated(uint8 indexed tier, uint128 priceUSD);
    event HookUpdated(address hook);
    event Withdrawal(address indexed to, uint256 amount);
    event ProjectNameUpdated(string name);
    event ProjectSymbolUpdated(string symbol);

    // --- State ---

    // Project metadata
    string public projectName;
    string public projectSymbol;

    // Pricing
    uint128[] public tierPrices;

    // Hook
    ISubscriptionHook public hook;

    // Subscription counter
    uint256 internal _tokenIdCounter;

    function totalSupply() public view virtual returns (uint256) {
        return _tokenIdCounter;
    }

    // Subscriptions
    mapping(address => uint256) public subscription;
    mapping(uint256 => uint64) public startedAt;
    mapping(uint256 => uint64) public expiresAt;
    mapping(uint256 => TierPeriod[]) internal _tierPeriods;

    // --- Constructor ---

    constructor(
        string memory _projectName,
        string memory _projectSymbol,
        address _priceFeed,
        uint128[] memory _tierPrices,
        uint256 _saleStart
    ) Ownable(msg.sender) HasPriceFeed(_priceFeed) WithSaleStart(_saleStart) {
        projectName = _projectName;
        projectSymbol = _projectSymbol;
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

        (uint256 tokenId, bool active, uint8 previousTier) = _resolveSubscription(recipient);

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
            newExpiry = _addDuration(expiresAt[tokenId], adj.adjustedDuration);
        } else {
            (required, newExpiry) = _changeTier(expiresAt[tokenId], previousTier, tier, adj);
        }

        if (msg.value < required) revert InsufficientPayment();

        tokenId = _applySubscription(recipient, tokenId, tier, newExpiry, start);
        _notifyHook(h, previousTier, tier, recipient);
        _afterSubscriptionChange(tokenId);
        emit Supported(recipient, tier, tokenId, duration, required, newExpiry);

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

        (uint256 tokenId, bool active, uint8 previousTier) = _resolveSubscription(recipient);

        if (!active && duration == 0) revert InvalidDuration();

        uint64 start = startAt != 0 ? startAt : uint64(block.timestamp);
        uint64 base = active ? expiresAt[tokenId] : start;
        uint64 newExpiry = _addDuration(base, duration);

        tokenId = _applySubscription(recipient, tokenId, tier, newExpiry, start);
        _notifyHook(hook, previousTier, tier, recipient);
        _afterSubscriptionChange(tokenId);
        emit Supported(recipient, tier, tokenId, duration, 0, newExpiry);
    }

    /// @notice Get cost and adjusted duration for a tier and duration.
    function estimate(uint8 tier, uint32 duration, address subscriber) external view returns (uint256 ethCost, uint32 adjustedDuration) {
        if (tier >= tierPrices.length) revert InvalidTier();
        if (duration == 0) revert InvalidDuration();
        (, bool active, uint8 previousTier) = _resolveSubscription(subscriber);
        ISubscriptionHook.Adjustments memory adj = _beforeSubscribe(
            hook, tier, duration, subscriber, !active, previousTier
        );
        ethCost = _baseCost(adj.adjustedUSD);
        adjustedDuration = adj.adjustedDuration;
    }

    /// @notice Get the tier periods of a subscription.
    function tierPeriods(uint256 tokenId) external view returns (TierPeriod[] memory) {
        return _tierPeriods[tokenId];
    }

    /// @notice Get the current tier for a subscription.
    function currentTier(uint256 tokenId) external view returns (uint8 tier, bool active) {
        return _currentTier(tokenId);
    }

    /// @notice Check whether a subscriber's subscription is currently active.
    function isActive(address subscriber) public view returns (bool) {
        uint256 tokenId = subscription[subscriber];
        return tokenId != 0 && block.timestamp < expiresAt[tokenId];
    }

    // --- Owner ---

    /// @notice Get the number of available tiers.
    function totalTiers() public view returns (uint256) {
        return tierPrices.length;
    }

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

    /// @notice Update the project name.
    function setProjectName(string calldata _name) external onlyOwner {
        projectName = _name;
        emit ProjectNameUpdated(_name);
    }

    /// @notice Update the project symbol.
    function setProjectSymbol(string calldata _symbol) external onlyOwner {
        projectSymbol = _symbol;
        emit ProjectSymbolUpdated(_symbol);
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
    function _onNewSubscription(address recipient, uint256 tokenId) internal virtual {}

    /// @dev Called after any subscription change. Override to add side effects (e.g. metadata update events).
    function _afterSubscriptionChange(uint256 tokenId) internal virtual {}

    // --- Subscription Internals ---

    /// @dev Resolve the subscriber's token and subscription state.
    function _resolveSubscription(address subscriber) internal view returns (
        uint256 tokenId, bool active, uint8 previousTier
    ) {
        if (subscriber == address(0)) return (0, false, type(uint8).max);
        tokenId = subscription[subscriber];
        active = tokenId != 0 && block.timestamp < expiresAt[tokenId];
        previousTier = tokenId != 0 ? _lastTier(tokenId) : type(uint8).max;
    }

    /// @dev Notify the hook of a tier change.
    function _notifyHook(ISubscriptionHook h, uint8 previousTier, uint8 tier, address recipient) internal {
        if (address(h) == address(0)) return;
        if (previousTier != type(uint8).max && previousTier != tier) {
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
            if (rawExpiry < minExpiry) rawExpiry = minExpiry;
        }

        newExpiry = rawExpiry > type(uint64).max ? type(uint64).max : uint64(rawExpiry);
    }

    function _applySubscription(
        address recipient, uint256 tokenId, uint8 tier, uint64 newExpiry, uint64 start
    ) internal returns (uint256) {
        if (tokenId == 0) {
            tokenId = ++_tokenIdCounter;
            _onNewSubscription(recipient, tokenId);
        }

        if (block.timestamp >= expiresAt[tokenId]) {
            // New or reactivated — reset
            startedAt[tokenId] = start;
            delete _tierPeriods[tokenId];
            _tierPeriods[tokenId].push(TierPeriod(tier, start));
        } else if (tier != _lastTier(tokenId)) {
            _tierPeriods[tokenId].push(TierPeriod(tier, uint64(block.timestamp)));
        }

        subscription[recipient] = tokenId;
        expiresAt[tokenId] = newExpiry;
        return tokenId;
    }

    /// @dev Safely add duration months to a base timestamp, capping at uint64 max.
    function _addDuration(uint64 base, uint32 duration) internal pure returns (uint64) {
        uint256 result = uint256(base) + uint256(duration) * 30 days;
        return result > type(uint64).max ? type(uint64).max : uint64(result);
    }

    // --- Subscription helpers ---

    function _currentTier(uint256 tokenId) internal view returns (uint8, bool) {
        uint64 end = expiresAt[tokenId];
        if (end == 0 || block.timestamp >= end) return (0, false);
        return (_lastTier(tokenId), true);
    }

    function _lastTier(uint256 tokenId) internal view returns (uint8) {
        TierPeriod[] storage segs = _tierPeriods[tokenId];
        return segs[segs.length - 1].tier;
    }

    // --- Pricing ---

    function _beforeSubscribe(
        ISubscriptionHook h, uint8 tier, uint32 duration, address subscriber, bool isNew, uint8 previousTier
    ) internal view returns (ISubscriptionHook.Adjustments memory adj) {
        uint256 baseUSD = uint256(tierPrices[tier]) * duration;
        if (address(h) == address(0)) {
            return ISubscriptionHook.Adjustments(baseUSD, duration, 0);
        }
        adj = h.beforeSubscribe(tier, duration, baseUSD, subscriber, isNew, previousTier);
    }

    function _baseCost(uint256 adjustedUSD) internal view returns (uint256) {
        if (adjustedUSD == 0) return 0;
        return _usdToEth(adjustedUSD);
    }

}
