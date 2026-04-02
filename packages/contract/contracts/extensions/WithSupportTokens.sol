// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {OnePerWallet} from "@1001-digital/erc721-extensions/contracts/OnePerWallet.sol";
import {Support} from "../Support.sol";
import {ISupportRenderer} from "../interfaces/ISupportRenderer.sol";
import {TierPeriod} from "../interfaces/Types.sol";
import {ISubscriptionHook} from "../interfaces/ISubscriptionHook.sol";

/// @title WithSupportTokens
/// @notice Extension that represents support subscriptions as ERC-721 tokens (one per wallet).
abstract contract WithSupportTokens is Support, OnePerWallet {

    // --- Events ---

    event MetadataUpdate(uint256 tokenId);
    event LogoUpdated();
    event RendererUpdated(address renderer);

    // --- State ---

    ISupportRenderer public renderer;
    string public logo;

    // --- Constructor ---

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _logo,
        address _renderer
    ) ERC721(_name, _symbol) {
        logo = _logo;
        renderer = ISupportRenderer(_renderer);
    }

    // --- ERC-721 Overrides ---

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        address owner = _requireOwned(tokenId);

        (uint8 tier, bool active) = currentTier(tokenId);
        uint8 displayTier = active ? tier : _lastTier(tokenId);

        ISupportRenderer.TokenData memory data = ISupportRenderer.TokenData({
            tokenId: tokenId,
            subscriber: owner,
            projectName: name(),
            logo: logo,
            startedAt: startedAt[tokenId],
            expiresAt: expiresAt[tokenId],
            displayTier: displayTier,
            active: active,
            tierPeriods: tierHistory[tokenId]
        });

        return renderer.tokenURI(data);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x49064906 // ERC-4906
            || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);

        if (from == address(0) || to == address(0)) return from;

        bool wasActive = block.timestamp < expiresAt[tokenId];
        uint8 tier;
        if (wasActive) tier = _lastTier(tokenId);

        subscription[from] = 0;
        subscription[to] = tokenId; // always track, even if expired — so re-subscribe finds it

        if (wasActive) {
            ISubscriptionHook h = hook;
            if (address(h) != address(0)) {
                h.onRelease(tier, from);
                h.onSubscribe(tier, to);
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
