// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TierPeriod} from "./Types.sol";

interface ISupportRenderer {
    struct TokenData {
        uint256 tokenId;
        address supporter;
        string projectName;
        string logo;
        uint64 startedAt;
        uint64 expiresAt;
        uint64 createdAt;
        uint64 saleStart;
        uint8 displayTier;
        bool active;
        TierPeriod[] tierPeriods;
    }

    function tokenURI(TokenData calldata data) external view returns (string memory);
}
