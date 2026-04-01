// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {HasPriceFeed, AggregatorV3Interface} from "@1001-digital/erc721-extensions/contracts/HasPriceFeed.sol";
import {WithSaleStart} from "@1001-digital/erc721-extensions/contracts/WithSaleStart.sol";
import {Segment} from "./ISupportRenderer.sol";
import {IPricingHook} from "./IPricingHook.sol";
import {IGuardHook} from "./IGuardHook.sol";

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
    event PricingHookUpdated(address pricingHook);
    event GuardUpdated(address guard);
    event Withdrawal(address indexed to, uint256 amount);
    event ProjectNameUpdated(string name);
    event ProjectSymbolUpdated(string symbol);

    // --- State ---

    // Project metadata
    string public projectName;
    string public projectSymbol;

    // Pricing
    uint128[4] public tierPrices;
    IPricingHook public pricingHook;

    // Guard
    IGuardHook public guard;

    // Subscription counter
    uint256 internal _tokenIdCounter;

    function totalSupply() public view virtual returns (uint256) {
        return _tokenIdCounter;
    }

    // Subscriptions
    mapping(address => uint256) public activeToken;
    mapping(uint256 => uint64) public startedAt;
    mapping(uint256 => uint64) public expiresAt;
    mapping(uint256 => Segment[]) internal _segments;

    // --- Constructor ---

    constructor(
        string memory _projectName,
        string memory _projectSymbol,
        address _priceFeed,
        uint128[4] memory _tierPrices,
        uint256 _saleStart
    ) Ownable(msg.sender) HasPriceFeed(_priceFeed) WithSaleStart(_saleStart) {
        projectName = _projectName;
        projectSymbol = _projectSymbol;
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

        uint256 tokenId = _activeTokenOf(recipient);
        bool isActive = tokenId != 0;
        if (isActive && tier != _lastTier(tokenId)
            && msg.sender != recipient && msg.sender != owner()) {
            revert TierChangeForbidden();
        }

        uint256 required = _subscribe(recipient, tier, duration, false);

        if (msg.value < required) revert InsufficientPayment();

        uint256 excess = msg.value - required;
        if (excess > 0) {
            (bool sent, ) = msg.sender.call{value: excess}("");
            if (!sent) revert TransferFailed();
        }
    }

    /// @notice Grant a free subscription (owner only).
    function grant(address recipient, uint8 tier, uint32 duration) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();
        _subscribe(recipient, tier, duration, true);
    }

    /// @notice Get the base ETH cost for a tier and duration (new subscription).
    function cost(uint8 tier, uint32 duration) external view returns (uint256) {
        if (tier >= 4) revert InvalidTier();
        if (duration == 0) revert InvalidDuration();
        return _baseCost(tier, duration, address(0));
    }

    /// @notice Get the segments of a subscription.
    function segments(uint256 tokenId) external view returns (Segment[] memory) {
        return _segments[tokenId];
    }

    /// @notice Get the current tier for a subscription.
    function currentTier(uint256 tokenId) external view returns (uint8 tier, bool active) {
        return _currentTier(tokenId);
    }

    /// @notice Get the active token for a supporter (0 if none/expired).
    function activeTokenOf(address supporter) public view returns (uint256) {
        return _activeTokenOf(supporter);
    }

    // --- Owner ---

    /// @notice Update a tier's monthly USD price.
    function setTierPrice(uint8 tier, uint128 priceUSD) external onlyOwner {
        if (tier >= 4) revert InvalidTier();
        tierPrices[tier] = priceUSD;
        emit TierPriceUpdated(tier, priceUSD);
    }

    /// @notice Set the pricing hook contract (address(0) to disable).
    function setPricingHook(IPricingHook _hook) external onlyOwner {
        pricingHook = _hook;
        emit PricingHookUpdated(address(_hook));
    }

    /// @notice Set the guard hook contract (address(0) to disable).
    function setGuard(IGuardHook _guard) external onlyOwner {
        guard = _guard;
        emit GuardUpdated(address(_guard));
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

    // --- Subscription ---

    function _subscribe(
        address recipient, uint8 tier, uint32 duration, bool free
    ) internal returns (uint256 required) {
        if (tier >= 4) revert InvalidTier();

        uint256 previousTokenId = activeToken[recipient];
        uint256 tokenId = _syncActiveToken(recipient);
        bool isNew = tokenId == 0;

        if (tokenId != 0) previousTokenId = tokenId;
        uint8 previousTier = previousTokenId != 0 ? _lastTier(previousTokenId) : type(uint8).max;

        // New subscriptions require duration >= 1. Active tier changes allow 0.
        if (duration == 0 && (isNew || tier == previousTier)) revert InvalidDuration();
        uint64 newExpiry;

        if (isNew) {
            if (!free) required = _baseCost(tier, duration, recipient);
            newExpiry = _addDuration(uint64(block.timestamp), duration);
        } else if (tier == previousTier) {
            if (!free) required = _baseCost(tier, duration, recipient);
            newExpiry = _addDuration(expiresAt[tokenId], duration);
        } else {
            (required, newExpiry) = _changeTier(expiresAt[tokenId], previousTier, tier, duration, free, recipient);
        }

        tokenId = _applySubscription(recipient, tokenId, isNew, tier, newExpiry);

        IGuardHook g = guard;
        if (address(g) != address(0)) {
            if (previousTier != type(uint8).max && previousTier != tier) {
                g.onRelease(previousTier, recipient);
            }
            g.onSubscribe(tier, recipient);
        }

        _afterSubscriptionChange(tokenId);
        emit Supported(recipient, tier, tokenId, duration, required, newExpiry);
    }

    function _changeTier(
        uint64 currentExpiry, uint8 fromTier, uint8 toTier, uint32 duration, bool free, address subscriber
    ) private view returns (uint256 required, uint64 newExpiry) {
        uint64 remaining = currentExpiry - uint64(block.timestamp);
        uint128 oldPrice = tierPrices[fromTier];
        uint128 newPrice = tierPrices[toTier];

        if (newPrice > oldPrice) {
            if (!free) {
                uint256 diffUSD = uint256(newPrice - oldPrice) * remaining / 30 days;
                required = _usdToEth(diffUSD + _adjustedUSD(toTier, duration, subscriber));
            }
            newExpiry = _addDuration(currentExpiry, duration);
            return (required, newExpiry);
        }

        if (!free) required = _baseCost(toTier, duration, subscriber);
        uint256 converted = newPrice == 0
            ? uint256(remaining)
            : uint256(remaining) * oldPrice / newPrice;
        uint256 rawExpiry = uint256(block.timestamp) + converted + uint256(duration) * 30 days;
        newExpiry = rawExpiry > type(uint64).max ? type(uint64).max : uint64(rawExpiry);
    }

    function _applySubscription(
        address recipient, uint256 tokenId, bool isNew, uint8 tier, uint64 newExpiry
    ) internal returns (uint256) {
        if (isNew) {
            tokenId = ++_tokenIdCounter;
            _onNewSubscription(recipient, tokenId);
            activeToken[recipient] = tokenId;
            startedAt[tokenId] = uint64(block.timestamp);
            _segments[tokenId].push(Segment(tier, uint64(block.timestamp)));
        } else if (tier != _lastTier(tokenId)) {
            _segments[tokenId].push(Segment(tier, uint64(block.timestamp)));
        }

        expiresAt[tokenId] = newExpiry;
        return tokenId;
    }

    function _activeTokenOf(address supporter) internal view virtual returns (uint256 tokenId) {
        tokenId = activeToken[supporter];
        if (tokenId == 0 || block.timestamp >= expiresAt[tokenId]) {
            return 0;
        }
    }

    function _syncActiveToken(address supporter) internal virtual returns (uint256 tokenId) {
        tokenId = _activeTokenOf(supporter);
        if (activeToken[supporter] != tokenId) {
            activeToken[supporter] = tokenId;
        }
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
        Segment[] storage segs = _segments[tokenId];
        return segs[segs.length - 1].tier;
    }

    // --- Pricing ---

    function _adjustedUSD(uint8 tier, uint32 duration, address subscriber) internal view returns (uint256) {
        uint256 baseUSD = uint256(tierPrices[tier]) * duration;
        IPricingHook hook = pricingHook;
        if (address(hook) == address(0)) return baseUSD;
        return hook.adjustCost(tier, duration, baseUSD, subscriber);
    }

    function _baseCost(uint8 tier, uint32 duration, address subscriber) internal view returns (uint256) {
        uint256 usd = _adjustedUSD(tier, duration, subscriber);
        if (usd == 0) return 0;
        return _usdToEth(usd);
    }

}
