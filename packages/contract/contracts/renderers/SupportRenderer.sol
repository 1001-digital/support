// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {LibString} from "solady/src/utils/LibString.sol";
import {WithENSReverseLookup} from "@1001-digital/erc721-extensions/contracts/WithENSReverseLookup.sol";
import {ISupportRenderer, TierPeriod} from "../interfaces/ISupportRenderer.sol";

contract SupportRenderer is ISupportRenderer, WithENSReverseLookup {

    function tokenURI(TokenData calldata data) external view returns (string memory) {
        string memory safeName = LibString.escapeHTML(data.projectName);
        string memory svg = _buildSVG(data, safeName);

        string memory json = string.concat(
            '{"name":"', LibString.escapeJSON(data.projectName, false), ' #', Strings.toString(data.tokenId),
            '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)),
            '","attributes":[', _attributes(data), ']}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // --- SVG ---

    function _buildSVG(TokenData calldata data, string memory safeName) internal view returns (string memory) {
        uint256 dayNum = (block.timestamp - data.startedAt) / 1 days + 1;
        uint256 dur = data.active
            ? (block.timestamp - data.startedAt) / 1 days
            : (data.expiresAt - data.startedAt) / 1 days;

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">'
            '<rect width="400" height="400" fill="white"/>'
            '<style>.l{font-family:monospace;fill:#666;text-transform:uppercase;font-size:10px;font-weight:500}</style>'
            '<text class="l" x="20" y="30">', safeName, ' SUPPORTERS</text>'
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

        for (uint256 i; i < data.tierPeriods.length; ++i) {
            uint64 segEnd = i + 1 < data.tierPeriods.length ? data.tierPeriods[i + 1].startedAt : data.expiresAt;
            attrs = string.concat(
                attrs,
                ',{"trait_type":"Tier Period ', Strings.toString(i + 1),
                '","value":"Tier ', Strings.toString(data.tierPeriods[i].tier),
                ', ', Strings.toString((segEnd - data.tierPeriods[i].startedAt) / 1 days), 'd"}'
            );
        }

        return attrs;
    }

}
