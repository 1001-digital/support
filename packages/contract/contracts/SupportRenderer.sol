// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ISupportRenderer, Segment} from "./ISupportRenderer.sol";

contract SupportRenderer is ISupportRenderer {

    function tokenURI(TokenData calldata data) external view returns (string memory) {
        string memory svg = _buildSVG(data);

        string memory json = string.concat(
            '{"name":"', data.projectName, ' #', Strings.toString(data.tokenId),
            '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)),
            '","attributes":[', _attributes(data), ']}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // --- SVG ---

    function _buildSVG(TokenData calldata data) internal view returns (string memory) {
        uint256 dayNum = (block.timestamp - data.startedAt) / 1 days + 1;
        uint256 dur = data.active
            ? (block.timestamp - data.startedAt) / 1 days
            : (data.expiresAt - data.startedAt) / 1 days;

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">'
            '<rect width="400" height="400" fill="white"/>'
            '<style>.l{font-family:monospace;fill:#666;text-transform:uppercase;font-size:10px;font-weight:500}</style>'
            '<text class="l" x="20" y="30">', data.projectName, ' SUPPORTERS</text>'
            '<text class="l" x="380" y="30" text-anchor="end">', _displayName(data.subscriber), '</text>',
            _badge(data.displayTier, data.logo),
            '<text class="l" x="20" y="380">DAY ', Strings.toString(dayNum), '</text>'
            '<text class="l" x="200" y="380" text-anchor="middle">', data.active ? 'ACTIVE' : 'EXPIRED', '</text>'
            '<text class="l" x="380" y="380" text-anchor="end">', Strings.toString(dur), 'D</text>'
            '</svg>'
        );
    }

    /// @dev Builds the center badge: rounded rect, logo left, tier name right.
    function _badge(uint8 tier, string calldata logo) internal pure returns (string memory) {
        string memory bg;
        string memory tc;
        string memory t;
        uint256 w;

        if (tier == 0)      { bg = '#DCDCDC'; tc = '#484848'; t = 'SUPPORTER'; w = 120; }
        else if (tier == 1) { bg = '#A29C7A'; tc = '#fff';    t = 'GOLD';      w = 81;  }
        else if (tier == 2) { bg = '#8B8F9A'; tc = '#fff';    t = 'PLATINUM';  w = 109; }
        else                { bg = '#000';    tc = '#fff';    t = 'PARTNER';   w = 102; }

        uint256 x = (400 - w) / 2;
        uint256 textX = 26 + (w - 26) / 2;

        return string.concat(
            '<g transform="translate(', Strings.toString(x), ',184)">',
            '<rect width="', Strings.toString(w), '" height="32" rx="3" fill="', bg, '"/>',
            '<g transform="translate(3,3)">', logo, '</g>',
            '<text x="', Strings.toString(textX), '" y="20" text-anchor="middle" font-family="monospace" font-size="12" font-weight="bold" fill="', tc, '">', t, '</text>',
            '</g>'
        );
    }

    // --- Attributes ---

    function _attributes(TokenData calldata data) internal pure returns (string memory) {
        string memory attrs = string.concat(
            '{"trait_type":"Status","value":"', data.active ? 'Active' : 'Expired', '"},',
            '{"trait_type":"Tier","value":', Strings.toString(data.displayTier), '},',
            '{"trait_type":"Started At","display_type":"date","value":', Strings.toString(uint256(data.startedAt)), '},',
            '{"trait_type":"Expires At","display_type":"date","value":', Strings.toString(uint256(data.expiresAt)), '}'
        );

        for (uint256 i; i < data.segments.length; ++i) {
            uint64 segEnd = i + 1 < data.segments.length ? data.segments[i + 1].startedAt : data.expiresAt;
            attrs = string.concat(
                attrs,
                ',{"trait_type":"Segment ', Strings.toString(i + 1),
                '","value":"Tier ', Strings.toString(data.segments[i].tier),
                ', ', Strings.toString((segEnd - data.segments[i].startedAt) / 1 days), 'd"}'
            );
        }

        return attrs;
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
