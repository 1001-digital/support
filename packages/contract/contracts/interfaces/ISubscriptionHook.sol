// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISubscriptionHook {
    /// @notice Revert with this to block a subscription in beforeSubscribe.
    error SubscriptionBlocked();

    /// @notice Adjustments returned by beforeSubscribe.
    struct Adjustments {
        uint256 adjustedUSD;      // Final USD cost
        uint32  adjustedDuration; // Duration in months after adjustment
        uint64  adjustedStart;    // Start timestamp for new subs (0 = use block.timestamp)
    }

    /// @notice Called before a subscription is applied. Returns adjusted parameters.
    /// @param tier          The target tier
    /// @param duration      Requested duration in months
    /// @param baseUSD       Raw tierPrice * duration before adjustments
    /// @param subscriber    The address being subscribed (address(0) for generic estimates)
    /// @param isNew         true if this is a brand new subscription
    /// @param previousTier  The subscriber's current tier (type(uint8).max if none)
    /// @return adj The adjusted subscription parameters
    function beforeSubscribe(
        uint8   tier,
        uint32  duration,
        uint256 baseUSD,
        address subscriber,
        bool    isNew,
        uint8   previousTier
    ) external view returns (Adjustments memory adj);

    /// @notice Check whether a subscription is allowed (for off-chain estimation).
    function canSubscribe(uint8 tier, address subscriber) external view returns (bool);

    /// @notice Called after a subscription is applied. Revert to block it.
    function onSubscribe(uint8 tier, address subscriber) external;

    /// @notice Called when a subscriber leaves a tier (upgrade, downgrade, or transfer).
    function onRelease(uint8 tier, address subscriber) external;
}
