// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IPricingHook {
    /// @notice Adjust the USD cost for a subscription.
    /// @param tier The subscription tier
    /// @param duration Number of months
    /// @param baseUSD The raw tierPrice * duration (before any adjustments)
    /// @param subscriber The address being subscribed (address(0) for generic estimates)
    /// @return adjustedUSD The final USD cost to charge
    function adjustCost(uint8 tier, uint32 duration, uint256 baseUSD, address subscriber)
        external view returns (uint256 adjustedUSD);
}
