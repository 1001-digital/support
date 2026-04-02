// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Support} from "../Support.sol";

/// @dev Minimal concrete Support without ERC-721 tokens, for testing the base contract in isolation.
contract MockSupport is Support {
    constructor(
        string memory _projectName,
        string memory _projectSymbol,
        address _priceFeed,
        uint128[] memory _tierPrices,
        uint256 _saleStart
    ) Support(_projectName, _projectSymbol, _priceFeed, _tierPrices, _saleStart) {}
}
