// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WithSupportTokens} from "./WithSupportTokens.sol";
import {Support} from "./Support.sol";

/// @title SupportToken
/// @notice Concrete support contract with ERC-721 token representation.
contract SupportToken is WithSupportTokens {

    constructor(
        string memory _projectName,
        string memory _projectSymbol,
        string memory _logo,
        address _priceFeed,
        uint128[4] memory _tierPrices,
        uint16 _discountMinMonths,
        uint16 _discountPercentOff,
        address _renderer,
        uint256 _saleStart
    ) Support(_projectName, _projectSymbol, _priceFeed, _tierPrices, _discountMinMonths, _discountPercentOff, _saleStart)
      WithSupportTokens(_logo, _renderer)
    {}

}
