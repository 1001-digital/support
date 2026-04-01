// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPricingHook} from "../interfaces/IPricingHook.sol";

/// @title DiscountPricingHook
/// @notice Applies a percentage discount when duration meets a minimum threshold.
contract DiscountPricingHook is IPricingHook, Ownable {

    error InvalidDiscount();

    event DiscountUpdated(uint16 minMonths, uint16 percentOff);

    uint16 public minMonths;
    uint16 public percentOff;

    constructor(uint16 _minMonths, uint16 _percentOff) Ownable(msg.sender) {
        if (_percentOff > 100) revert InvalidDiscount();
        minMonths = _minMonths;
        percentOff = _percentOff;
    }

    function adjustCost(uint8, uint32 duration, uint256 baseUSD, address)
        external view override returns (uint256)
    {
        if (duration >= minMonths && minMonths > 0) {
            return baseUSD * (100 - percentOff) / 100;
        }
        return baseUSD;
    }

    function setDiscount(uint16 _minMonths, uint16 _percentOff) external onlyOwner {
        if (_percentOff > 100) revert InvalidDiscount();
        minMonths = _minMonths;
        percentOff = _percentOff;
        emit DiscountUpdated(_minMonths, _percentOff);
    }
}
