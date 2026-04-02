// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Support} from "../Support.sol";
import {ISupportRenderer, TierPeriod} from "../interfaces/ISupportRenderer.sol";
import {ISubscriptionHook} from "../interfaces/ISubscriptionHook.sol";

/// @title WithSupportTokens
/// @notice Extension that represents support subscriptions as ERC-721 tokens.
abstract contract WithSupportTokens is Support, ERC721Enumerable {

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
        address owner = _requireOwned(tokenId);

        (uint8 tier, bool active) = _currentTier(tokenId);
        uint8 displayTier = active ? tier : _lastTier(tokenId);

        ISupportRenderer.TokenData memory data = ISupportRenderer.TokenData({
            tokenId: tokenId,
            subscriber: owner,
            projectName: projectName,
            logo: logo,
            startedAt: startedAt[tokenId],
            expiresAt: expiresAt[tokenId],
            displayTier: displayTier,
            active: active,
            tierPeriods: _tierPeriods[tokenId]
        });

        return renderer.tokenURI(data);
    }

    function totalSupply() public view override(Support, ERC721Enumerable) returns (uint256) {
        return super.totalSupply();
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable) returns (bool) {
        return interfaceId == 0x49064906 // ERC-4906
            || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);

        if (from == address(0) || to == address(0)) return from;

        bool wasActive = block.timestamp < expiresAt[tokenId];
        uint8 tier;
        if (wasActive) tier = _lastTier(tokenId);

        _transferActiveToken(from, tokenId);
        _receiveActiveToken(to, tokenId);

        if (wasActive) {
            ISubscriptionHook h = hook;
            if (address(h) != address(0)) {
                if (!_hasActiveTierToken(from, tier)) {
                    h.onRelease(tier, from);
                }
                if (_hasActiveTierToken(to, tier)) {
                    h.onSubscribe(tier, to);
                }
            }
        }

        return from;
    }

    /// @dev When the sender's active token is transferred, find a replacement.
    function _transferActiveToken(address from, uint256 tokenId) private {
        if (activeToken[from] != tokenId) return;

        uint256 replacement;
        uint256 balance = balanceOf(from);
        for (uint256 i; i < balance; ++i) {
            uint256 candidate = tokenOfOwnerByIndex(from, i);
            if (block.timestamp < expiresAt[candidate]) {
                replacement = candidate;
                break;
            }
        }
        activeToken[from] = replacement;
    }

    /// @dev Assign the transferred token as active if the receiver has no other
    ///      active token. Skips the transferred token when scanning so that
    ///      _activeTokenOf (which would find it) is not used.
    function _receiveActiveToken(address to, uint256 tokenId) private {
        if (block.timestamp >= expiresAt[tokenId]) return;

        uint256 existing = activeToken[to];
        if (existing != 0 && block.timestamp < expiresAt[existing]) return;

        uint256 balance = balanceOf(to);
        for (uint256 i; i < balance; ++i) {
            uint256 candidate = tokenOfOwnerByIndex(to, i);
            if (candidate != tokenId && block.timestamp < expiresAt[candidate]) {
                return;
            }
        }

        activeToken[to] = tokenId;
    }

    // --- Hook Overrides ---

    function _onNewSubscription(address recipient, uint256 tokenId) internal override {
        _mint(recipient, tokenId);
    }

    function _afterSubscriptionChange(uint256 tokenId) internal override {
        emit MetadataUpdate(tokenId);
    }

    function _activeTokenOf(address supporter) internal view override returns (uint256 tokenId) {
        tokenId = activeToken[supporter];
        if (tokenId != 0 && block.timestamp < expiresAt[tokenId]) {
            return tokenId;
        }

        uint256 balance = balanceOf(supporter);
        for (uint256 i; i < balance; ++i) {
            uint256 candidate = tokenOfOwnerByIndex(supporter, i);
            if (block.timestamp < expiresAt[candidate]) {
                return candidate;
            }
        }

        return 0;
    }

    function _hasActiveTierToken(address supporter, uint8 tier) private view returns (bool) {
        uint256 balance = balanceOf(supporter);
        for (uint256 i; i < balance; ++i) {
            uint256 tokenId = tokenOfOwnerByIndex(supporter, i);
            if (block.timestamp < expiresAt[tokenId] && _lastTier(tokenId) == tier) {
                return true;
            }
        }

        return false;
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
