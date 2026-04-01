// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

struct Segment {
    uint8 tier;
    uint64 startedAt;
}

interface ISupportRenderer {
    struct TokenData {
        uint256 tokenId;
        address subscriber;
        string projectName;
        string logo;
        uint64 startedAt;
        uint64 expiresAt;
        uint8 displayTier;
        bool active;
        Segment[] segments;
    }

    function tokenURI(TokenData calldata data) external view returns (string memory);
}
