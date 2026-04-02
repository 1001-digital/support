// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

struct TierPeriod {
    uint8 tier;
    uint64 startedAt;
}

struct SubscriptionData {
    uint64 createdAt;
    uint64 startedAt;
    uint64 expiresAt;
}
