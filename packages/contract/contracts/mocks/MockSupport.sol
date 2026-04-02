// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Support} from "../Support.sol";
import {ISubscriptionHook} from "../interfaces/ISubscriptionHook.sol";

/// @dev Minimal concrete Support without ERC-721 tokens, for testing the base contract in isolation.
contract MockSupport is Support {
    constructor(
        address _initialOwner,
        address _priceFeed,
        uint128[] memory _tierPrices,
        uint256 _saleStart,
        ISubscriptionHook _hook
    ) Support(_initialOwner, _priceFeed, _tierPrices, _saleStart, _hook) {}
}
