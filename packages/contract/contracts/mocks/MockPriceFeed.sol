// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockPriceFeed as Mock} from "@1001-digital/erc721-extensions/contracts/mocks/MockPriceFeed.sol";

contract MockPriceFeed is Mock {
    constructor(int256 _price) Mock(_price) {}
}
