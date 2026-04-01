export const SupportAbi = [
  // --- Events ---
  {
    type: "event",
    name: "Supported",
    inputs: [
      { indexed: true, name: "supporter", type: "address" },
      { indexed: true, name: "tier", type: "uint8" },
      { indexed: true, name: "tokenId", type: "uint256" },
      { indexed: false, name: "duration", type: "uint32" },
      { indexed: false, name: "paid", type: "uint256" },
      { indexed: false, name: "expiresAt", type: "uint64" },
    ],
  },
  {
    type: "event",
    name: "Transfer",
    inputs: [
      { indexed: true, name: "from", type: "address" },
      { indexed: true, name: "to", type: "address" },
      { indexed: true, name: "tokenId", type: "uint256" },
    ],
  },
  {
    type: "event",
    name: "Approval",
    inputs: [
      { indexed: true, name: "owner", type: "address" },
      { indexed: true, name: "approved", type: "address" },
      { indexed: true, name: "tokenId", type: "uint256" },
    ],
  },
  {
    type: "event",
    name: "ApprovalForAll",
    inputs: [
      { indexed: true, name: "owner", type: "address" },
      { indexed: true, name: "operator", type: "address" },
      { indexed: false, name: "approved", type: "bool" },
    ],
  },
  {
    type: "event",
    name: "MetadataUpdate",
    inputs: [
      { indexed: false, name: "tokenId", type: "uint256" },
    ],
  },
  {
    type: "event",
    name: "TierPriceUpdated",
    inputs: [
      { indexed: true, name: "tier", type: "uint8" },
      { indexed: false, name: "priceUSD", type: "uint128" },
    ],
  },
  {
    type: "event",
    name: "DiscountUpdated",
    inputs: [
      { indexed: false, name: "minMonths", type: "uint16" },
      { indexed: false, name: "percentOff", type: "uint16" },
    ],
  },
  {
    type: "event",
    name: "MaxSlotsUpdated",
    inputs: [
      { indexed: true, name: "tier", type: "uint8" },
      { indexed: false, name: "maxSlots", type: "uint16" },
    ],
  },
  {
    type: "event",
    name: "Withdrawal",
    inputs: [
      { indexed: true, name: "to", type: "address" },
      { indexed: false, name: "amount", type: "uint256" },
    ],
  },
  {
    type: "event",
    name: "OwnershipTransferred",
    inputs: [
      { indexed: true, name: "previousOwner", type: "address" },
      { indexed: true, name: "newOwner", type: "address" },
    ],
  },
  {
    type: "event",
    name: "OwnershipTransferStarted",
    inputs: [
      { indexed: true, name: "previousOwner", type: "address" },
      { indexed: true, name: "newOwner", type: "address" },
    ],
  },
  {
    type: "event",
    name: "PriceFeedUpdated",
    inputs: [
      { indexed: false, name: "priceFeed", type: "address" },
    ],
  },
  {
    type: "event",
    name: "ProjectNameUpdated",
    inputs: [
      { indexed: false, name: "name", type: "string" },
    ],
  },
  {
    type: "event",
    name: "ProjectSymbolUpdated",
    inputs: [
      { indexed: false, name: "symbol", type: "string" },
    ],
  },
  {
    type: "event",
    name: "LogoUpdated",
    inputs: [],
  },

  // --- Public functions ---
  {
    type: "function",
    name: "support",
    stateMutability: "payable",
    inputs: [
      { name: "recipient", type: "address" },
      { name: "tier", type: "uint8" },
      { name: "duration", type: "uint32" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "grant",
    stateMutability: "nonpayable",
    inputs: [
      { name: "recipient", type: "address" },
      { name: "tier", type: "uint8" },
      { name: "duration", type: "uint32" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "cost",
    stateMutability: "view",
    inputs: [
      { name: "tier", type: "uint8" },
      { name: "duration", type: "uint32" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "segments",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ name: "", type: "tuple[]", components: [
      { name: "tier", type: "uint8" },
      { name: "startedAt", type: "uint64" },
    ]}],
  },
  {
    type: "function",
    name: "currentTier",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [
      { name: "tier", type: "uint8" },
      { name: "active", type: "bool" },
    ],
  },
  {
    type: "function",
    name: "tierHolders",
    stateMutability: "view",
    inputs: [{ name: "tier", type: "uint8" }],
    outputs: [{ name: "", type: "address[]" }],
  },

  // --- State getters ---
  {
    type: "function",
    name: "owner",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "pendingOwner",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "priceFeed",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "projectName",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "projectSymbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "tierPrices",
    stateMutability: "view",
    inputs: [{ name: "", type: "uint256" }],
    outputs: [{ name: "", type: "uint128" }],
  },
  {
    type: "function",
    name: "discountMinMonths",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint16" }],
  },
  {
    type: "function",
    name: "discountPercentOff",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint16" }],
  },
  {
    type: "function",
    name: "maxSlots",
    stateMutability: "view",
    inputs: [{ name: "", type: "uint256" }],
    outputs: [{ name: "", type: "uint16" }],
  },
  {
    type: "function",
    name: "activeToken",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "startedAt",
    stateMutability: "view",
    inputs: [{ name: "", type: "uint256" }],
    outputs: [{ name: "", type: "uint64" }],
  },
  {
    type: "function",
    name: "expiresAt",
    stateMutability: "view",
    inputs: [{ name: "", type: "uint256" }],
    outputs: [{ name: "", type: "uint64" }],
  },

  // --- ERC-721 ---
  {
    type: "function",
    name: "name",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "totalSupply",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "_owner", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "ownerOf",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "tokenURI",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "getApproved",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "isApprovedForAll",
    stateMutability: "view",
    inputs: [
      { name: "_owner", type: "address" },
      { name: "operator", type: "address" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },

  // --- ERC-721 (continued) ---
  {
    type: "function",
    name: "safeTransferFrom",
    stateMutability: "nonpayable",
    inputs: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "tokenId", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "safeTransferFrom",
    stateMutability: "nonpayable",
    inputs: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "tokenId", type: "uint256" },
      { name: "data", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "supportsInterface",
    stateMutability: "view",
    inputs: [{ name: "interfaceId", type: "bytes4" }],
    outputs: [{ name: "", type: "bool" }],
  },

  // --- Owner functions ---
  {
    type: "function",
    name: "acceptOwnership",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    type: "function",
    name: "setPriceFeed",
    stateMutability: "nonpayable",
    inputs: [{ name: "_priceFeed", type: "address" }],
    outputs: [],
  },
  {
    type: "function",
    name: "setTierPrice",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tier", type: "uint8" },
      { name: "priceUSD", type: "uint128" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setDiscount",
    stateMutability: "nonpayable",
    inputs: [
      { name: "minMonths", type: "uint16" },
      { name: "percentOff", type: "uint16" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setMaxSlots",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tier", type: "uint8" },
      { name: "max", type: "uint16" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setProjectName",
    stateMutability: "nonpayable",
    inputs: [{ name: "_name", type: "string" }],
    outputs: [],
  },
  {
    type: "function",
    name: "setProjectSymbol",
    stateMutability: "nonpayable",
    inputs: [{ name: "_symbol", type: "string" }],
    outputs: [],
  },
  {
    type: "function",
    name: "setLogo",
    stateMutability: "nonpayable",
    inputs: [{ name: "_logo", type: "string" }],
    outputs: [],
  },
  {
    type: "function",
    name: "withdraw",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    type: "function",
    name: "transferOwnership",
    stateMutability: "nonpayable",
    inputs: [{ name: "newOwner", type: "address" }],
    outputs: [],
  },
  {
    type: "function",
    name: "transferFrom",
    stateMutability: "nonpayable",
    inputs: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "tokenId", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "tokenId", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setApprovalForAll",
    stateMutability: "nonpayable",
    inputs: [
      { name: "operator", type: "address" },
      { name: "approved", type: "bool" },
    ],
    outputs: [],
  },
] as const;
