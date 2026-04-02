// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISubscriptionHook} from "../interfaces/ISubscriptionHook.sol";

/// @title DiscountHook
/// @notice Applies a percentage discount when duration meets a minimum threshold.
contract DiscountHook is ISubscriptionHook, Ownable {

    error InvalidDiscount();

    event DiscountUpdated(uint16 minMonths, uint16 percentOff);

    uint16 public minMonths;
    uint16 public percentOff;

    constructor(uint16 _minMonths, uint16 _percentOff) Ownable(msg.sender) {
        if (_percentOff > 100) revert InvalidDiscount();
        minMonths = _minMonths;
        percentOff = _percentOff;
    }

    function beforeSubscribe(
        uint8, uint32 duration, uint256 baseUSD, address, bool, uint8
    ) external view virtual override returns (Adjustments memory adj) {
        return _applyDiscount(duration, baseUSD);
    }

    function _applyDiscount(uint32 duration, uint256 baseUSD) internal view returns (Adjustments memory adj) {
        adj.adjustedDuration = duration;
        adj.adjustedUSD = (duration >= minMonths && minMonths > 0)
            ? baseUSD * (100 - percentOff) / 100
            : baseUSD;
    }

    function canSubscribe(uint8, address) external pure virtual override returns (bool) {
        return true;
    }

    function onSubscribe(uint8, address) external virtual override {}
    function onRelease(uint8, address) external virtual override {}

    function setDiscount(uint16 _minMonths, uint16 _percentOff) external onlyOwner {
        if (_percentOff > 100) revert InvalidDiscount();
        minMonths = _minMonths;
        percentOff = _percentOff;
        emit DiscountUpdated(_minMonths, _percentOff);
    }
}
