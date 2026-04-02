// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISupport {
    function support(address recipient, uint8 tier, uint32 duration) external payable;
    function subscription(address subscriber) external view returns (uint256);
    function currentTier(uint256 subscriptionId) external view returns (uint8 tier, bool active);
}
