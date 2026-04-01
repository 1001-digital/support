// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISubscriptionHook} from "../interfaces/ISubscriptionHook.sol";

interface ISupportRead {
    function activeTokenOf(address supporter) external view returns (uint256);
    function currentTier(uint256 tokenId) external view returns (uint8 tier, bool active);
}

/// @title MaxSlotsHook
/// @notice Enforces a maximum number of active subscribers per tier.
contract MaxSlotsHook is ISubscriptionHook, Ownable {

    error TierFull();
    error InvalidTier();
    error OnlySupport();

    event MaxSlotsUpdated(uint8 indexed tier, uint16 maxSlots);

    address public immutable support;
    uint16[4] public maxSlots;

    mapping(uint8 => address[]) internal _tierHolders;
    mapping(uint8 => mapping(address => uint256)) internal _tierHolderIndex; // 1-indexed; 0 = not present

    modifier onlySupport() {
        if (msg.sender != support) revert OnlySupport();
        _;
    }

    constructor(address _support) Ownable(msg.sender) {
        support = _support;
    }

    // --- ISubscriptionHook ---

    function beforeSubscribe(
        uint8 tier, uint32 duration, uint256 baseUSD, address subscriber, bool, uint8
    ) external view override returns (Adjustments memory adj) {
        if (!_canSubscribe(tier, subscriber)) revert SubscriptionBlocked();
        adj.adjustedUSD = baseUSD;
        adj.adjustedDuration = duration;
        adj.adjustedStart = 0;
    }

    function canSubscribe(uint8 tier, address subscriber) external view override returns (bool) {
        return _canSubscribe(tier, subscriber);
    }

    function onSubscribe(uint8 tier, address subscriber) external override onlySupport {
        uint16 max = maxSlots[tier];
        if (max == 0) return;
        if (_tierHolderIndex[tier][subscriber] != 0) return;

        address[] storage holders = _tierHolders[tier];

        if (holders.length < max) {
            holders.push(subscriber);
            _tierHolderIndex[tier][subscriber] = holders.length;
            return;
        }

        for (uint256 i; i < holders.length; ++i) {
            if (!_isActiveOnTier(holders[i], tier)) {
                delete _tierHolderIndex[tier][holders[i]];
                holders[i] = subscriber;
                _tierHolderIndex[tier][subscriber] = i + 1;
                return;
            }
        }

        revert TierFull();
    }

    function onRelease(uint8 tier, address supporter) external override onlySupport {
        uint256 idx = _tierHolderIndex[tier][supporter];
        if (idx == 0) return;

        address[] storage holders = _tierHolders[tier];
        uint256 lastIndex = holders.length - 1;
        uint256 removeIndex = idx - 1;

        if (removeIndex != lastIndex) {
            address last = holders[lastIndex];
            holders[removeIndex] = last;
            _tierHolderIndex[tier][last] = idx;
        }

        holders.pop();
        delete _tierHolderIndex[tier][supporter];
    }

    // --- Owner ---

    function setMaxSlots(uint8 tier, uint16 max) external onlyOwner {
        if (tier >= 4) revert InvalidTier();
        maxSlots[tier] = max;
        emit MaxSlotsUpdated(tier, max);
    }

    // --- Views ---

    function tierHolders(uint8 tier) external view returns (address[] memory) {
        return _tierHolders[tier];
    }

    function activeTierHolders(uint8 tier) external view returns (address[] memory) {
        address[] storage holders = _tierHolders[tier];
        uint256 count;
        for (uint256 i; i < holders.length; ++i) {
            if (_isActiveOnTier(holders[i], tier)) ++count;
        }
        address[] memory active = new address[](count);
        uint256 j;
        for (uint256 i; i < holders.length; ++i) {
            if (_isActiveOnTier(holders[i], tier)) active[j++] = holders[i];
        }
        return active;
    }

    // --- Internal ---

    function _canSubscribe(uint8 tier, address subscriber) internal view returns (bool) {
        uint16 max = maxSlots[tier];
        if (max == 0) return true;
        if (_tierHolderIndex[tier][subscriber] != 0) return true;
        if (_tierHolders[tier].length < max) return true;

        address[] storage holders = _tierHolders[tier];
        for (uint256 i; i < holders.length; ++i) {
            if (!_isActiveOnTier(holders[i], tier)) return true;
        }
        return false;
    }

    function _isActiveOnTier(address holder, uint8 tier) internal view returns (bool) {
        uint256 tokenId = ISupportRead(support).activeTokenOf(holder);
        if (tokenId == 0) return false;
        (uint8 t, bool active) = ISupportRead(support).currentTier(tokenId);
        return active && t == tier;
    }
}
