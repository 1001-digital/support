// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

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
contract Support is ERC721, Ownable2Step {

    // --- Errors ---

    error InvalidTier();
    error InvalidDuration();
    error InvalidRecipient();
    error InvalidDiscount();
    error InsufficientPayment();
    error TransferFailed();
    error StalePrice();
    error NothingToWithdraw();
    error TierFull();
    error TierChangeForbidden();
    error InvalidPriceFeed();
    error UnsafeString();

    // --- Types ---

    struct Segment {
        uint8 tier;
        uint64 startedAt;
    }

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
    event MetadataUpdate(uint256 tokenId);
    event PriceFeedUpdated(address priceFeed);
    event ProjectNameUpdated(string name);
    event ProjectSymbolUpdated(string symbol);
    event LogoUpdated();

    // --- State ---

    AggregatorV3Interface public priceFeed;

    // Project metadata
    string public projectName;
    string public projectSymbol;
    string public logo;

    // Pricing
    uint128[4] public tierPrices;
    uint16 public discountMinMonths;
    uint16 public discountPercentOff;
    uint16[4] public maxSlots;

    // Token counter
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
        string memory _logo,
        address _priceFeed,
        uint128[4] memory _tierPrices,
        uint16 _discountMinMonths,
        uint16 _discountPercentOff
    ) ERC721("", "") Ownable(msg.sender) {
        if (_discountPercentOff > 100) revert InvalidDiscount();
        projectName = _projectName;
        projectSymbol = _projectSymbol;
        logo = _logo;
        priceFeed = AggregatorV3Interface(_priceFeed);
        tierPrices = _tierPrices;
        discountMinMonths = _discountMinMonths;
        discountPercentOff = _discountPercentOff;
    }

    // --- ERC-721 Overrides ---

    function name() public view override returns (string memory) {
        return projectName;
    }

    function symbol() public view override returns (string memory) {
        return projectSymbol;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        (uint8 tier, bool active) = _currentTier(tokenId);
        uint8 displayTier = active ? tier : _lastTier(tokenId);

        string memory svg = _buildSVG(tokenId, displayTier, active);

        string memory json = string.concat(
            '{"name":"', projectName, ' #', Strings.toString(tokenId),
            '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)),
            '","attributes":[', _attributes(tokenId, displayTier, active), ']}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x49064906 // ERC-4906
            || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);

        // Subscription bookkeeping on transfer (not on mint)
        if (from != address(0) && to != address(0)) {
            if (activeToken[from] == tokenId) activeToken[from] = 0;

            if (block.timestamp < expiresAt[tokenId]) {
                uint256 existing = activeToken[to];
                if (existing == 0 || block.timestamp >= expiresAt[existing]) {
                    activeToken[to] = tokenId;
                }
            }
        }

        return from;
    }

    function renounceOwnership() public pure override {
        revert();
    }

    // --- Public ---

    /// @notice Subscribe an address at a given tier for a number of months.
    /// @dev Third parties can extend or start subscriptions, but only the
    ///      recipient (or owner) may change tiers.
    function support(address recipient, uint8 tier, uint32 duration) external payable {
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

    /// @notice Update the Chainlink price feed address.
    function setPriceFeed(address _priceFeed) external onlyOwner {
        if (_priceFeed == address(0)) revert InvalidPriceFeed();
        priceFeed = AggregatorV3Interface(_priceFeed);
        emit PriceFeedUpdated(_priceFeed);
    }

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
        _requireSafeString(_name);
        projectName = _name;
        emit ProjectNameUpdated(_name);
    }

    /// @notice Update the project symbol.
    function setProjectSymbol(string calldata _symbol) external onlyOwner {
        _requireSafeString(_symbol);
        projectSymbol = _symbol;
        emit ProjectSymbolUpdated(_symbol);
    }

    /// @notice Update the logo SVG content.
    function setLogo(string calldata _logo) external onlyOwner {
        logo = _logo;
        emit LogoUpdated();
    }

    /// @notice Withdraw all collected ETH.
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToWithdraw();
        (bool sent, ) = owner().call{value: balance}("");
        if (!sent) revert TransferFailed();
        emit Withdrawal(owner(), balance);
    }

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

        emit MetadataUpdate(tokenId);
        emit Supported(recipient, tier, tokenId, duration, required, newExpiry);
    }

    function _applySubscription(
        address recipient, uint256 tokenId, bool isNew, uint8 tier, uint64 newExpiry
    ) internal returns (uint256) {
        if (isNew) {
            tokenId = ++totalSupply;
            _mint(recipient, tokenId);
            activeToken[recipient] = tokenId;
            startedAt[tokenId] = uint64(block.timestamp);
            _segments[tokenId].push(Segment(tier, uint64(block.timestamp)));
        } else if (tier != _lastTier(tokenId)) {
            _segments[tokenId].push(Segment(tier, uint64(block.timestamp)));
        }

        expiresAt[tokenId] = newExpiry;
        subscriberOf[tokenId] = recipient;
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

    // --- Token helpers ---

    function _currentTier(uint256 tokenId) internal view returns (uint8, bool) {
        uint64 end = expiresAt[tokenId];
        if (end == 0 || block.timestamp >= end) return (0, false);
        return (_lastTier(tokenId), true);
    }

    function _lastTier(uint256 tokenId) internal view returns (uint8) {
        Segment[] storage segs = _segments[tokenId];
        return segs[segs.length - 1].tier;
    }

    // --- Metadata ---

    function _buildSVG(uint256 tokenId, uint8 displayTier, bool active) internal view returns (string memory) {
        uint64 start = startedAt[tokenId];
        uint256 dayNum = (block.timestamp - start) / 1 days + 1;
        uint256 dur = active
            ? (block.timestamp - start) / 1 days
            : (expiresAt[tokenId] - start) / 1 days;

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">'
            '<rect width="400" height="400" fill="white"/>'
            '<style>.l{font-family:monospace;fill:#666;text-transform:uppercase;font-size:10px;font-weight:500}</style>'
            '<text class="l" x="20" y="30">', projectName, ' SUPPORTERS</text>'
            '<text class="l" x="380" y="30" text-anchor="end">', _displayName(subscriberOf[tokenId]), '</text>',
            _badge(displayTier),
            '<text class="l" x="20" y="380">DAY ', Strings.toString(dayNum), '</text>'
            '<text class="l" x="200" y="380" text-anchor="middle">', active ? 'ACTIVE' : 'EXPIRED', '</text>'
            '<text class="l" x="380" y="380" text-anchor="end">', Strings.toString(dur), 'D</text>'
            '</svg>'
        );
    }

    /// @dev Builds the center badge: rounded rect, logo left, tier name right.
    function _badge(uint8 tier) internal view returns (string memory) {
        string memory bg;
        string memory tc;
        string memory t;
        uint256 w;

        if (tier == 0)      { bg = '#DCDCDC'; tc = '#484848'; t = 'SUPPORTER'; w = 120; }
        else if (tier == 1) { bg = '#A29C7A'; tc = '#fff';    t = 'GOLD';      w = 81;  }
        else if (tier == 2) { bg = '#8B8F9A'; tc = '#fff';    t = 'PLATINUM';  w = 109; }
        else                { bg = '#000';    tc = '#fff';    t = 'PARTNER';   w = 102; }

        uint256 x = (400 - w) / 2;
        uint256 textX = 26 + (w - 26) / 2; // center text in area right of logo

        return string.concat(
            '<g transform="translate(', Strings.toString(x), ',184)">',
            '<rect width="', Strings.toString(w), '" height="32" rx="3" fill="', bg, '"/>',
            '<g transform="translate(3,3)">', logo, '</g>',
            '<text x="', Strings.toString(textX), '" y="20" text-anchor="middle" font-family="monospace" font-size="12" font-weight="bold" fill="', tc, '">', t, '</text>',
            '</g>'
        );
    }

    function _attributes(uint256 tokenId, uint8 displayTier, bool active) internal view returns (string memory) {
        string memory attrs = string.concat(
            '{"trait_type":"Status","value":"', active ? 'Active' : 'Expired', '"},',
            '{"trait_type":"Tier","value":', Strings.toString(displayTier), '},',
            '{"trait_type":"Started At","display_type":"date","value":', Strings.toString(uint256(startedAt[tokenId])), '},',
            '{"trait_type":"Expires At","display_type":"date","value":', Strings.toString(uint256(expiresAt[tokenId])), '}'
        );

        Segment[] storage segs = _segments[tokenId];
        for (uint256 i; i < segs.length; ++i) {
            uint64 segEnd = i + 1 < segs.length ? segs[i + 1].startedAt : expiresAt[tokenId];
            attrs = string.concat(
                attrs,
                ',{"trait_type":"Segment ', Strings.toString(i + 1),
                '","value":"Tier ', Strings.toString(segs[i].tier),
                ', ', Strings.toString((segEnd - segs[i].startedAt) / 1 days), 'd"}'
            );
        }

        return attrs;
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

    function _usdToEth(uint256 usdAmount) internal view returns (uint256) {
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound)
            = priceFeed.latestRoundData();
        if (price <= 0) revert StalePrice();
        if (answeredInRound < roundId) revert StalePrice();
        if (block.timestamp - updatedAt > 1 hours) revert StalePrice();
        return usdAmount * 1e18 / uint256(price);
    }

    // --- Validation ---

    /// @dev Reject strings containing characters that break JSON or SVG embedding.
    function _requireSafeString(string calldata s) internal pure {
        bytes calldata b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == '"' || c == '<' || c == '>' || c == '\\') revert UnsafeString();
        }
    }

    // --- ENS ---

    /// @dev namehash("addr.reverse")
    bytes32 internal constant ADDR_REVERSE_NODE = 0x91d1777781884d03a6757a803996e38de2a42967fb37eeaca72729271025a9e2;

    address internal constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;

    /// @dev Try ENS reverse resolution, fall back to short hex.
    function _displayName(address addr) internal view returns (string memory) {
        if (ENS_REGISTRY.code.length == 0) return _shortHex(addr);

        bytes32 node = keccak256(abi.encodePacked(ADDR_REVERSE_NODE, _sha3Hex(addr)));

        try IENS(ENS_REGISTRY).resolver(node) returns (address resolver) {
            if (resolver != address(0) && resolver.code.length > 0) {
                try IENSResolver(resolver).name(node) returns (string memory ensName) {
                    if (bytes(ensName).length > 0) return ensName;
                } catch {}
            }
        } catch {}

        return _shortHex(addr);
    }

    /// @dev keccak256 of the lowercase hex representation of an address (no 0x prefix).
    function _sha3Hex(address addr) internal pure returns (bytes32) {
        bytes memory result = new bytes(40);
        uint160 val = uint160(addr);
        unchecked {
            for (uint256 i = 40; i > 0; --i) {
                result[i - 1] = _HEX_LOWER[val & 0xf];
                val >>= 4;
            }
        }
        return keccak256(result);
    }

    bytes internal constant _HEX_LOWER = "0123456789abcdef";
    bytes internal constant _HEX = "0123456789ABCDEF";

    /// @dev Returns "0x1234...5678" (6 prefix + 4 suffix).
    function _shortHex(address addr) internal pure returns (string memory) {
        bytes memory full = new bytes(40);
        uint160 val = uint160(addr);
        unchecked {
            for (uint256 i = 40; i > 0; --i) {
                full[i - 1] = _HEX[val & 0xf];
                val >>= 4;
            }
        }
        return string.concat(
            "0x", string(abi.encodePacked(full[0], full[1], full[2], full[3])),
            "...",
            string(abi.encodePacked(full[36], full[37], full[38], full[39]))
        );
    }

}

interface IENS {
    function resolver(bytes32 node) external view returns (address);
}

interface IENSResolver {
    function name(bytes32 node) external view returns (string memory);
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}
