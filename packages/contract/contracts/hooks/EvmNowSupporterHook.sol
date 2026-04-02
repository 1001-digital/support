// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DiscountHook} from "./DiscountHook.sol";

/// @title EvmNowSupporterHook
/// @notice Custom hook for EVM.NOW: 20% discount for 12+ months, Partner tier is grant-only.
contract EvmNowSupporterHook is DiscountHook {

    uint8 private constant PARTNER_TIER = 3;

    constructor() DiscountHook(12, 20) {}

    function beforeSubscribe(
        uint8 tier, uint32 duration, uint256 baseUSD, address, bool, uint8
    ) external view override returns (Adjustments memory adj) {
        if (tier == PARTNER_TIER) revert SubscriptionBlocked();
        return _applyDiscount(duration, baseUSD);
    }

    function canSubscribe(uint8 tier, address) external pure override returns (bool) {
        return tier != PARTNER_TIER;
    }
}
