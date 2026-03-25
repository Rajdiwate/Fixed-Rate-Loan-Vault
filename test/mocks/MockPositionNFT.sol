// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/// @dev Minimal position NFT mock exposing ownerOf.
contract MockPositionNFT {
  mapping(uint256 => address) internal _owners;
  uint256 internal _nextId = 1;
  address public vaultController;

  function setOwner(uint256 tokenId, address owner) external {
    _owners[tokenId] = owner;
  }

  function ownerOf(uint256 tokenId) external view returns (address) {
    return _owners[tokenId];
  }

  function mint(address to) external returns (uint256 tokenId) {
    tokenId = _nextId;
    _nextId += 1;
    _owners[tokenId] = to;
  }

  function setVaultController(address vaultController_) external {
    vaultController = vaultController_;
  }
}
