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
    uint256 public totalSupply;

    // Subscriptions
    mapping(address => uint256) public activeToken;
    mapping(uint256 => uint64) public startedAt;
    mapping(uint256 => uint64) public expiresAt;
    mapping(uint256 => address) public subscriberOf;
    mapping(uint256 => Segment[]) internal _segments;

    // Tier slots
    mapping(uint8 => address[]) internal _tierHolders;

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

    /// @notice Get the active holders for a tier.
    function tierHolders(uint8 tier) external view returns (address[] memory) {
        return _tierHolders[tier];
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

        // New subscriptions require duration >= 1. Active tier changes allow 0.
        if (duration == 0 && (isNew || tier == _lastTier(tokenId))) revert InvalidDuration();
        uint64 newExpiry;

        if (isNew) {
            if (!free) required = _baseCost(tier, duration);
            newExpiry = _addDuration(uint64(block.timestamp), duration);
        } else {
            uint8 activeTier = _lastTier(tokenId);

            if (tier == activeTier) {
                if (!free) required = _baseCost(tier, duration);
                newExpiry = _addDuration(expiresAt[tokenId], duration);
            } else {
                uint64 remaining = expiresAt[tokenId] - uint64(block.timestamp);
                uint128 oldPrice = tierPrices[activeTier];
                uint128 newPrice = tierPrices[tier];

                if (newPrice > oldPrice) {
                    if (!free) {
                        uint256 diffUSD = uint256(newPrice - oldPrice) * remaining / 30 days;
                        required = _usdToEth(diffUSD + _discountedUSD(tier, duration));
                    }
                    newExpiry = _addDuration(expiresAt[tokenId], duration);
                } else {
                    if (!free) required = _baseCost(tier, duration);
                    uint256 rawConverted = newPrice == 0
                        ? uint256(remaining)
                        : uint256(remaining) * oldPrice / newPrice;
                    uint256 rawExpiry = uint256(block.timestamp) + rawConverted + uint256(duration) * 30 days;
                    newExpiry = rawExpiry > type(uint64).max ? type(uint64).max : uint64(rawExpiry);
                }
            }
        }

        tokenId = _applySubscription(recipient, tokenId, isNew, tier, newExpiry);
        _claimTierSlot(tier, recipient);

        _afterSubscriptionChange(tokenId);
        emit Supported(recipient, tier, tokenId, duration, required, newExpiry);
    }

    function _applySubscription(
        address recipient, uint256 tokenId, bool isNew, uint8 tier, uint64 newExpiry
    ) internal returns (uint256) {
        if (isNew) {
            tokenId = ++totalSupply;
            _onNewSubscription(recipient, tokenId);
            activeToken[recipient] = tokenId;
            subscriberOf[tokenId] = recipient;
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

        address[] storage holders = _tierHolders[tier];

        for (uint256 i; i < holders.length; ++i) {
            if (holders[i] == supporter) return;
        }

        for (uint256 i; i < holders.length; ++i) {
            uint256 token = activeToken[holders[i]];
            if (token == 0
                || block.timestamp >= expiresAt[token]
                || _lastTier(token) != tier) {
                holders[i] = supporter;
                return;
            }
        }

        if (holders.length < max) {
            holders.push(supporter);
            return;
        }

        revert TierFull();
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
