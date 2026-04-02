// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISupport} from "../interfaces/ISupport.sol";

/// @dev Attempts reentrancy through the excess-refund path in support().
contract ReentrancyAttacker {
    ISupport public immutable target;
    uint8 public attackTier;
    uint32 public attackDuration;
    uint256 public reentrancyCount;
    uint256 public maxReentries;

    constructor(address _target) {
        target = ISupport(_target);
    }

    function attack(uint8 tier, uint32 duration, uint256 _maxReentries) external payable {
        attackTier = tier;
        attackDuration = duration;
        maxReentries = _maxReentries;
        reentrancyCount = 0;
        target.support{value: msg.value}(address(this), tier, duration);
    }

    receive() external payable {
        if (reentrancyCount < maxReentries && address(this).balance > 0) {
            reentrancyCount++;
            target.support{value: address(this).balance}(address(this), attackTier, attackDuration);
        }
    }
}
