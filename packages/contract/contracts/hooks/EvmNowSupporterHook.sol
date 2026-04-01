// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISubscriptionHook} from "../interfaces/ISubscriptionHook.sol";

/// @title EvmNowSupporterHook
/// @notice Custom hook for EVM.NOW: 20% discount for 12+ months, Partner tier is grant-only.
contract EvmNowSupporterHook is ISubscriptionHook {

    uint8  private constant PARTNER_TIER = 3;
    uint16 private constant MIN_MONTHS   = 12;
    uint16 private constant PERCENT_OFF  = 20;

    function beforeSubscribe(
        uint8 tier, uint32 duration, uint256 baseUSD, address, bool, uint8
    ) external pure override returns (Adjustments memory adj) {
        if (tier == PARTNER_TIER) revert SubscriptionBlocked();

        adj.adjustedDuration = duration;

        if (duration >= MIN_MONTHS) {
            adj.adjustedUSD = baseUSD * (100 - PERCENT_OFF) / 100;
        } else {
            adj.adjustedUSD = baseUSD;
        }
    }

    function canSubscribe(uint8 tier, address) external pure override returns (bool) {
        return tier != PARTNER_TIER;
    }

    function onSubscribe(uint8, address) external override {}
    function onRelease(uint8, address) external override {}
}
