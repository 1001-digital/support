// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {HasPriceFeed, AggregatorV3Interface} from "@1001-digital/erc721-extensions/contracts/HasPriceFeed.sol";
import {WithSaleStart} from "@1001-digital/erc721-extensions/contracts/WithSaleStart.sol";
import {Segment} from "./ISupportRenderer.sol";

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
    error InvalidDiscount();
    error InsufficientPayment();
    error TransferFailed();
    error NothingToWithdraw();
    error TierFull();
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
    event DiscountUpdated(uint16 minMonths, uint16 percentOff);
    event MaxSlotsUpdated(uint8 indexed tier, uint16 maxSlots);
    event Withdrawal(address indexed to, uint256 amount);
    event ProjectNameUpdated(string name);
    event ProjectSymbolUpdated(string symbol);

    // --- State ---

    // Project metadata
    string public projectName;
    string public projectSymbol;

    // Pricing
    uint128[4] public tierPrices;
    uint16 public discountMinMonths;
    uint16 public discountPercentOff;
    uint16[4] public maxSlots;

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

    // Tier slots
    mapping(uint8 => address[]) internal _tierHolders;
    mapping(uint8 => mapping(address => uint256)) internal _tierHolderIndex; // 1-indexed; 0 = not present

    // --- Constructor ---

    constructor(
        string memory _projectName,
        string memory _projectSymbol,
        address _priceFeed,
        uint128[4] memory _tierPrices,
        uint16 _discountMinMonths,
        uint16 _discountPercentOff,
        uint256 _saleStart
    ) Ownable(msg.sender) HasPriceFeed(_priceFeed) WithSaleStart(_saleStart) {
        if (_discountPercentOff > 100) revert InvalidDiscount();
        projectName = _projectName;
        projectSymbol = _projectSymbol;
        tierPrices = _tierPrices;
        discountMinMonths = _discountMinMonths;
        discountPercentOff = _discountPercentOff;
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

        uint256 tokenId = activeToken[recipient];
        bool isActive = tokenId != 0 && block.timestamp < expiresAt[tokenId];
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
        return _baseCost(tier, duration);
    }

    /// @notice Get the segments of a subscription.
    function segments(uint256 tokenId) external view returns (Segment[] memory) {
        return _segments[tokenId];
    }

    /// @notice Get the current tier for a subscription.
    function currentTier(uint256 tokenId) external view returns (uint8 tier, bool active) {
        return _currentTier(tokenId);
    }

    /// @notice Get the holders array for a tier (may contain stale entries).
    /// @dev Use activeTierHolders() for a filtered list.
    function tierHolders(uint8 tier) external view returns (address[] memory) {
        return _tierHolders[tier];
    }

    /// @notice Get only the currently active holders for a tier.
    function activeTierHolders(uint8 tier) external view returns (address[] memory) {
        address[] storage holders = _tierHolders[tier];
        uint256 count;
        for (uint256 i; i < holders.length; ++i) {
            address holder = holders[i];
            uint256 token = activeToken[holder];
            if (token != 0 && block.timestamp < expiresAt[token] && _lastTier(token) == tier) {
                ++count;
            }
        }
        address[] memory active = new address[](count);
        uint256 j;
        for (uint256 i; i < holders.length; ++i) {
            address holder = holders[i];
            uint256 token = activeToken[holder];
            if (token != 0 && block.timestamp < expiresAt[token] && _lastTier(token) == tier) {
                active[j++] = holder;
            }
        }
        return active;
    }


    // --- Owner ---

    /// @notice Update a tier's monthly USD price.
    function setTierPrice(uint8 tier, uint128 priceUSD) external onlyOwner {
        if (tier >= 4) revert InvalidTier();
        tierPrices[tier] = priceUSD;
        emit TierPriceUpdated(tier, priceUSD);
    }

    /// @notice Update the bulk discount parameters.
    function setDiscount(uint16 minMonths, uint16 percentOff) external onlyOwner {
        if (percentOff > 100) revert InvalidDiscount();
        discountMinMonths = minMonths;
        discountPercentOff = percentOff;
        emit DiscountUpdated(minMonths, percentOff);
    }

    /// @notice Set the max active subscribers for a tier (0 = unlimited).
    function setMaxSlots(uint8 tier, uint16 max) external onlyOwner {
        if (tier >= 4) revert InvalidTier();
        maxSlots[tier] = max;
        emit MaxSlotsUpdated(tier, max);
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

        uint256 tokenId = activeToken[recipient];
        bool isNew = tokenId == 0 || block.timestamp >= expiresAt[tokenId];

        uint8 previousTier = tokenId != 0 ? _lastTier(tokenId) : type(uint8).max;

        // New subscriptions require duration >= 1. Active tier changes allow 0.
        if (duration == 0 && (isNew || tier == previousTier)) revert InvalidDuration();
        uint64 newExpiry;

        if (isNew) {
            if (!free) required = _baseCost(tier, duration);
            newExpiry = _addDuration(uint64(block.timestamp), duration);
        } else if (tier == previousTier) {
            if (!free) required = _baseCost(tier, duration);
            newExpiry = _addDuration(expiresAt[tokenId], duration);
        } else {
            (required, newExpiry) = _changeTier(expiresAt[tokenId], previousTier, tier, duration, free);
        }

        tokenId = _applySubscription(recipient, tokenId, isNew, tier, newExpiry);

        if (previousTier != type(uint8).max && previousTier != tier) {
            _removeFromTier(previousTier, recipient);
        }
        _claimTierSlot(tier, recipient);

        _afterSubscriptionChange(tokenId);
        emit Supported(recipient, tier, tokenId, duration, required, newExpiry);
    }

    function _changeTier(
        uint64 currentExpiry, uint8 fromTier, uint8 toTier, uint32 duration, bool free
    ) private view returns (uint256 required, uint64 newExpiry) {
        uint64 remaining = currentExpiry - uint64(block.timestamp);
        uint128 oldPrice = tierPrices[fromTier];
        uint128 newPrice = tierPrices[toTier];

        if (newPrice > oldPrice) {
            if (!free) {
                uint256 diffUSD = uint256(newPrice - oldPrice) * remaining / 30 days;
                required = _usdToEth(diffUSD + _discountedUSD(toTier, duration));
            }
            newExpiry = _addDuration(currentExpiry, duration);
            return (required, newExpiry);
        }

        if (!free) required = _baseCost(toTier, duration);
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

    // --- Tier slots ---

    function _claimTierSlot(uint8 tier, address supporter) internal {
        uint16 max = maxSlots[tier];
        if (max == 0) return;

        // O(1) membership check
        if (_tierHolderIndex[tier][supporter] != 0) return;

        address[] storage holders = _tierHolders[tier];

        // Room available — append
        if (holders.length < max) {
            holders.push(supporter);
            _tierHolderIndex[tier][supporter] = holders.length;
            return;
        }

        // Full — try to evict one stale entry
        for (uint256 i; i < holders.length; ++i) {
            address holder = holders[i];
            uint256 token = activeToken[holder];
            if (token == 0
                || block.timestamp >= expiresAt[token]
                || _lastTier(token) != tier) {
                delete _tierHolderIndex[tier][holder];
                holders[i] = supporter;
                _tierHolderIndex[tier][supporter] = i + 1;
                return;
            }
        }

        revert TierFull();
    }

    function _removeFromTier(uint8 tier, address supporter) internal {
        uint256 idx = _tierHolderIndex[tier][supporter];
        if (idx == 0) return;

        address[] storage holders = _tierHolders[tier];
        uint256 lastIndex = holders.length - 1;
        uint256 removeIndex = idx - 1;

        if (removeIndex != lastIndex) {
            address last = holders[lastIndex];
            holders[removeIndex] = last;
            _tierHolderIndex[tier][last] = idx;
        }

        holders.pop();
        delete _tierHolderIndex[tier][supporter];
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

    function _discountedUSD(uint8 tier, uint32 duration) internal view returns (uint256) {
        uint256 totalUSD = uint256(tierPrices[tier]) * duration;
        if (duration >= discountMinMonths && discountMinMonths > 0) {
            totalUSD = totalUSD * (100 - discountPercentOff) / 100;
        }
        return totalUSD;
    }

    function _baseCost(uint8 tier, uint32 duration) internal view returns (uint256) {
        uint256 usd = _discountedUSD(tier, duration);
        if (usd == 0) return 0;
        return _usdToEth(usd);
    }

}
