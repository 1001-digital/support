// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WithSupportTokens} from "./extensions/WithSupportTokens.sol";
import {Support} from "./Support.sol";
import {ISubscriptionHook} from "./interfaces/ISubscriptionHook.sol";

/// @title SupportToken
/// @notice Concrete support contract with ERC-721 token representation.
contract SupportToken is WithSupportTokens {

    constructor(
        address _initialOwner,
        string memory _projectName,
        string memory _projectSymbol,
        address _priceFeed,
        uint128[] memory _tierPrices,
        uint256 _saleStart,
        string memory _logo,
        address _renderer,
        ISubscriptionHook _hook
    ) Support(_initialOwner, _priceFeed, _tierPrices, _saleStart, _hook)
      WithSupportTokens(_projectName, _projectSymbol, _logo, _renderer)
    {}

}
