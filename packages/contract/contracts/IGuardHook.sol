// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IGuardHook {
    /// @notice Check whether a subscription is allowed (for off-chain estimation).
    function canSubscribe(uint8 tier, address subscriber) external view returns (bool);

    /// @notice Called after a subscription is applied. Revert to block it.
    function onSubscribe(uint8 tier, address subscriber) external;

    /// @notice Called when a subscriber leaves a tier (upgrade, downgrade, or transfer).
    function onRelease(uint8 tier, address subscriber) external;
}
