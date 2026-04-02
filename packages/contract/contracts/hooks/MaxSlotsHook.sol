// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISubscriptionHook} from "../interfaces/ISubscriptionHook.sol";
import {ISupport} from "../interfaces/ISupport.sol";

/// @title MaxSlotsHook
/// @notice Enforces a maximum number of active supporters per tier.
contract MaxSlotsHook is ISubscriptionHook, Ownable {

    error TierFull();
    error OnlySupport();

    event MaxSlotsUpdated(uint8 indexed tier, uint16 maxSlots);

    address public immutable support;
    mapping(uint8 => uint16) public maxSlots;

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
        uint8 tier, uint32 duration, uint256 baseUSD, address supporter, bool, uint8
    ) external view override returns (Adjustments memory adj) {
        if (!_canSubscribe(tier, supporter)) revert SubscriptionBlocked();
        adj.adjustedUSD = baseUSD;
        adj.adjustedDuration = duration;
        adj.adjustedStart = 0;
    }

    function canSubscribe(uint8 tier, address supporter) external view override returns (bool) {
        return _canSubscribe(tier, supporter);
    }

    function onSubscribe(uint8 tier, address supporter) external override onlySupport {
        uint16 max = maxSlots[tier];
        if (max == 0) return;
        if (_tierHolderIndex[tier][supporter] != 0) return;

        address[] storage holders = _tierHolders[tier];

        if (holders.length < max) {
            holders.push(supporter);
            _tierHolderIndex[tier][supporter] = holders.length;
            return;
        }

        for (uint256 i; i < holders.length; ++i) {
            if (!_isActiveOnTier(holders[i], tier)) {
                delete _tierHolderIndex[tier][holders[i]];
                holders[i] = supporter;
                _tierHolderIndex[tier][supporter] = i + 1;
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

    function _canSubscribe(uint8 tier, address supporter) internal view returns (bool) {
        uint16 max = maxSlots[tier];
        if (max == 0) return true;
        if (_tierHolderIndex[tier][supporter] != 0) return true;
        if (_tierHolders[tier].length < max) return true;

        address[] storage holders = _tierHolders[tier];
        for (uint256 i; i < holders.length; ++i) {
            if (!_isActiveOnTier(holders[i], tier)) return true;
        }
        return false;
    }

    function _isActiveOnTier(address holder, uint8 tier) internal view returns (bool) {
        uint256 tokenId = ISupport(support).subscription(holder);
        if (tokenId == 0) return false;
        (uint8 t, bool active) = ISupport(support).currentTier(tokenId);
        return active && t == tier;
    }
}
