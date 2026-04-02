// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Support} from "../Support.sol";

/// @dev Minimal concrete Support without ERC-721 tokens, for testing the base contract in isolation.
contract MockSupport is Support {
    constructor(
        address _initialOwner,
        address _priceFeed,
        uint128[] memory _tierPrices,
        uint256 _saleStart
    ) Support(_initialOwner, _priceFeed, _tierPrices, _saleStart) {}
}
