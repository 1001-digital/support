// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Support} from "./Support.sol";
import {ISupportRenderer, Segment} from "./ISupportRenderer.sol";

/// @title WithSupportTokens
/// @notice Extension that represents support subscriptions as ERC-721 tokens.
abstract contract WithSupportTokens is Support, ERC721 {

    // --- Events ---

    event MetadataUpdate(uint256 tokenId);
    event LogoUpdated();
    event RendererUpdated(address renderer);

    // --- State ---

    ISupportRenderer public renderer;
    string public logo;

    // --- Constructor ---

    constructor(
        string memory _logo,
        address _renderer
    ) ERC721("", "") {
        logo = _logo;
        renderer = ISupportRenderer(_renderer);
    }

    // --- ERC-721 Overrides ---

    function name() public view override returns (string memory) {
        return projectName;
    }

    function symbol() public view override returns (string memory) {
        return projectSymbol;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        (uint8 tier, bool active) = _currentTier(tokenId);
        uint8 displayTier = active ? tier : _lastTier(tokenId);

        ISupportRenderer.TokenData memory data = ISupportRenderer.TokenData({
            tokenId: tokenId,
            subscriber: subscriberOf[tokenId],
            projectName: projectName,
            logo: logo,
            startedAt: startedAt[tokenId],
            expiresAt: expiresAt[tokenId],
            displayTier: displayTier,
            active: active,
            segments: _segments[tokenId]
        });

        return renderer.tokenURI(data);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x49064906 // ERC-4906
            || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);

        // Subscription bookkeeping on transfer (not on mint)
        if (from != address(0) && to != address(0)) {
            if (activeToken[from] == tokenId) activeToken[from] = 0;

            if (block.timestamp < expiresAt[tokenId]) {
                uint256 existing = activeToken[to];
                if (existing == 0 || block.timestamp >= expiresAt[existing]) {
                    activeToken[to] = tokenId;
                }
            }
        }

        return from;
    }

    // --- Hook Overrides ---

    function _onNewSubscription(address recipient, uint256 tokenId) internal override {
        _mint(recipient, tokenId);
    }

    function _afterSubscriptionChange(uint256 tokenId) internal override {
        emit MetadataUpdate(tokenId);
    }

    // --- Owner ---

    /// @notice Update the logo SVG content.
    function setLogo(string calldata _logo) external onlyOwner {
        logo = _logo;
        emit LogoUpdated();
    }

    /// @notice Update the renderer contract.
    function setRenderer(address _renderer) external onlyOwner {
        renderer = ISupportRenderer(_renderer);
        emit RendererUpdated(_renderer);
    }

}
