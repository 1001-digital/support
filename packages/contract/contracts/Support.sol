// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
contract Support {

    // --- Errors ---

    error NotOwner();
    error InvalidOwner();
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
    error TokenDoesNotExist();
    error NotTokenOwner();
    error NotApproved();
    error UnsafeRecipient();

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
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event MetadataUpdate(uint256 tokenId);
    event ProjectNameUpdated(string name);
    event ProjectSymbolUpdated(string symbol);
    event LogoUpdated();

    // --- State ---

    address public owner;
    AggregatorV3Interface public immutable priceFeed;

    // Project metadata
    string public projectName;
    string public projectSymbol;
    string public logo;

    // Pricing
    uint128[4] public tierPrices;
    uint16 public discountMinMonths;
    uint16 public discountPercentOff;
    uint16[4] public maxSlots;

    // ERC-721
    uint256 public totalSupply;
    mapping(uint256 => address) internal _owners;
    mapping(address => uint256) internal _balances;
    mapping(uint256 => address) internal _tokenApprovals;
    mapping(address => mapping(address => bool)) internal _operatorApprovals;

    // Subscriptions
    mapping(address => uint256) public activeToken;
    mapping(uint256 => uint64) public startedAt;
    mapping(uint256 => uint64) public expiresAt;
    mapping(uint256 => address) public subscriberOf;
    mapping(uint256 => Segment[]) internal _segments;

    // Tier slots
    mapping(uint8 => address[]) internal _tierHolders;

    // --- Modifiers ---

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // --- Constructor ---

    constructor(
        string memory _projectName,
        string memory _projectSymbol,
        string memory _logo,
        address _priceFeed,
        uint128[4] memory _tierPrices,
        uint16 _discountMinMonths,
        uint16 _discountPercentOff
    ) {
        if (_discountPercentOff > 100) revert InvalidDiscount();
        owner = msg.sender;
        projectName = _projectName;
        projectSymbol = _projectSymbol;
        logo = _logo;
        priceFeed = AggregatorV3Interface(_priceFeed);
        tierPrices = _tierPrices;
        discountMinMonths = _discountMinMonths;
        discountPercentOff = _discountPercentOff;
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
            && msg.sender != recipient && msg.sender != owner) {
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

    /// @notice Update the logo SVG content.
    function setLogo(string calldata _logo) external onlyOwner {
        logo = _logo;
        emit LogoUpdated();
    }

    /// @notice Withdraw all collected ETH.
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToWithdraw();
        (bool sent, ) = owner.call{value: balance}("");
        if (!sent) revert TransferFailed();
        emit Withdrawal(owner, balance);
    }

    /// @notice Transfer contract ownership.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // --- ERC-721 ---

    function name() external view returns (string memory) {
        return projectName;
    }

    function symbol() external view returns (string memory) {
        return projectSymbol;
    }

    function balanceOf(address _owner) external view returns (uint256) {
        return _balances[_owner];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address o = _owners[tokenId];
        if (o == address(0)) revert TokenDoesNotExist();
        return o;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();

        (uint8 tier, bool active) = _currentTier(tokenId);
        uint8 displayTier = active ? tier : _lastTier(tokenId);

        string memory svg = _buildSVG(tokenId, displayTier, active);

        string memory json = string.concat(
            '{"name":"', projectName, ' #', _toString(tokenId),
            '","image":"data:image/svg+xml;base64,', _base64(bytes(svg)),
            '","attributes":[', _attributes(tokenId, displayTier, active), ']}'
        );

        return string.concat("data:application/json;base64,", _base64(bytes(json)));
    }

    function approve(address to, uint256 tokenId) external {
        address tokenOwner = ownerOf(tokenId);
        if (msg.sender != tokenOwner && !_operatorApprovals[tokenOwner][msg.sender])
            revert NotApproved();
        _tokenApprovals[tokenId] = to;
        emit Approval(tokenOwner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address _owner, address operator) external view returns (bool) {
        return _operatorApprovals[_owner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotApproved();
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 ret) {
                if (ret != IERC721Receiver.onERC721Received.selector) revert UnsafeRecipient();
            } catch {
                revert UnsafeRecipient();
            }
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x80ac58cd  // ERC-721
            || interfaceId == 0x5b5e139f  // ERC-721 Metadata
            || interfaceId == 0x49064906  // ERC-4906
            || interfaceId == 0x01ffc9a7; // ERC-165
    }

    // --- Transfer ---

    function _transfer(address from, address to, uint256 tokenId) internal {
        if (_owners[tokenId] != from) revert NotTokenOwner();
        if (to == address(0)) revert InvalidRecipient();

        delete _tokenApprovals[tokenId];

        --_balances[from];
        ++_balances[to];
        _owners[tokenId] = to;

        if (activeToken[from] == tokenId) activeToken[from] = 0;

        if (block.timestamp < expiresAt[tokenId]) {
            uint256 existing = activeToken[to];
            if (existing == 0 || block.timestamp >= expiresAt[existing]) {
                activeToken[to] = tokenId;
            }
        }

        emit Transfer(from, to, tokenId);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address tokenOwner = _owners[tokenId];
        if (tokenOwner == address(0)) revert TokenDoesNotExist();
        return spender == tokenOwner
            || _tokenApprovals[tokenId] == spender
            || _operatorApprovals[tokenOwner][spender];
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
            newExpiry = uint64(block.timestamp) + uint64(duration) * 30 days;
        } else {
            uint8 activeTier = _lastTier(tokenId);

            if (tier == activeTier) {
                if (!free) required = _baseCost(tier, duration);
                newExpiry = expiresAt[tokenId] + uint64(duration) * 30 days;
            } else {
                uint64 remaining = expiresAt[tokenId] - uint64(block.timestamp);
                uint128 oldPrice = tierPrices[activeTier];
                uint128 newPrice = tierPrices[tier];

                if (newPrice > oldPrice) {
                    if (!free) {
                        uint256 diffUSD = uint256(newPrice - oldPrice) * remaining / 30 days;
                        required = _usdToEth(diffUSD + _discountedUSD(tier, duration));
                    }
                    newExpiry = expiresAt[tokenId] + uint64(duration) * 30 days;
                } else {
                    if (!free) required = _baseCost(tier, duration);
                    uint64 converted = newPrice == 0
                        ? remaining
                        : uint64(uint256(remaining) * oldPrice / newPrice);
                    newExpiry = uint64(block.timestamp) + converted + uint64(duration) * 30 days;
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
            _owners[tokenId] = recipient;
            ++_balances[recipient];
            activeToken[recipient] = tokenId;
            startedAt[tokenId] = uint64(block.timestamp);
            _segments[tokenId].push(Segment(tier, uint64(block.timestamp)));
            emit Transfer(address(0), recipient, tokenId);
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
            '<text class="l" x="20" y="380">DAY ', _toString(dayNum), '</text>'
            '<text class="l" x="200" y="380" text-anchor="middle">', active ? 'ACTIVE' : 'EXPIRED', '</text>'
            '<text class="l" x="380" y="380" text-anchor="end">', _toString(dur), 'D</text>'
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
            '<g transform="translate(', _toString(x), ',184)">',
            '<rect width="', _toString(w), '" height="32" rx="3" fill="', bg, '"/>',
            '<g transform="translate(3,3)">', logo, '</g>',
            '<text x="', _toString(textX), '" y="20" text-anchor="middle" font-family="monospace" font-size="12" font-weight="bold" fill="', tc, '">', t, '</text>',
            '</g>'
        );
    }

    function _attributes(uint256 tokenId, uint8 displayTier, bool active) internal view returns (string memory) {
        string memory attrs = string.concat(
            '{"trait_type":"Status","value":"', active ? 'Active' : 'Expired', '"},',
            '{"trait_type":"Tier","value":', _toString(displayTier), '},',
            '{"trait_type":"Started At","display_type":"date","value":', _toString(uint256(startedAt[tokenId])), '},',
            '{"trait_type":"Expires At","display_type":"date","value":', _toString(uint256(expiresAt[tokenId])), '}'
        );

        Segment[] storage segs = _segments[tokenId];
        for (uint256 i; i < segs.length; ++i) {
            uint64 segEnd = i + 1 < segs.length ? segs[i + 1].startedAt : expiresAt[tokenId];
            attrs = string.concat(
                attrs,
                ',{"trait_type":"Segment ', _toString(i + 1),
                '","value":"Tier ', _toString(segs[i].tier),
                ', ', _toString((segEnd - segs[i].startedAt) / 1 days), 'd"}'
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

    // --- Utilities ---

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
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

    bytes internal constant _B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function _base64(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen);
        uint256 i;
        uint256 j;

        for (; i + 2 < data.length; i += 3) {
            uint24 chunk = uint24(uint8(data[i])) << 16
                | uint24(uint8(data[i + 1])) << 8
                | uint24(uint8(data[i + 2]));
            result[j++] = _B64[chunk >> 18 & 0x3F];
            result[j++] = _B64[chunk >> 12 & 0x3F];
            result[j++] = _B64[chunk >> 6 & 0x3F];
            result[j++] = _B64[chunk & 0x3F];
        }

        if (data.length % 3 == 1) {
            uint24 chunk = uint24(uint8(data[i])) << 16;
            result[j++] = _B64[chunk >> 18 & 0x3F];
            result[j++] = _B64[chunk >> 12 & 0x3F];
            result[j++] = "=";
            result[j++] = "=";
        } else if (data.length % 3 == 2) {
            uint24 chunk = uint24(uint8(data[i])) << 16
                | uint24(uint8(data[i + 1])) << 8;
            result[j++] = _B64[chunk >> 18 & 0x3F];
            result[j++] = _B64[chunk >> 12 & 0x3F];
            result[j++] = _B64[chunk >> 6 & 0x3F];
            result[j++] = "=";
        }

        return string(result);
    }
}

interface IENS {
    function resolver(bytes32 node) external view returns (address);
}

interface IENSResolver {
    function name(bytes32 node) external view returns (string memory);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external returns (bytes4);
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
