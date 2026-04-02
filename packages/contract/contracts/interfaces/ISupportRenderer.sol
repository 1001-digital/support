// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TierPeriod} from "./Types.sol";

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
        TierPeriod[] tierPeriods;
    }

    function tokenURI(TokenData calldata data) external view returns (string memory);
}
