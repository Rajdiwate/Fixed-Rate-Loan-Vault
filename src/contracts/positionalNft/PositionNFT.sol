// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPositionNFT} from "./IPositionNFT.sol";

/// @notice ERC-721 token representing institutional vault positions.
contract PositionNFT is Ownable2Step, ERC721, IPositionNFT {
  uint256 private _nextTokenId;
  address public vaultController;

  constructor(
    string memory name_,
    string memory symbol_,
    address vaultController_
  ) ERC721(name_, symbol_) Ownable(msg.sender) {
    _nextTokenId = 1;
    vaultController = vaultController_;
  }

  /// @inheritdoc IPositionNFT
  function mint(address to) external override returns (uint256 tokenId) {
    require(msg.sender == vaultController, "Not authorized");

    tokenId = _nextTokenId;
    _nextTokenId += 1;
    _mint(to, tokenId);
  }

  function setVaultController(address vaultController_) external override onlyOwner {
    vaultController = vaultController_;
  }

  /// @dev Restrict transfers of position NFTs so that only the contract owner
  /// (governance) can move existing tokens between institutions. Mints from
  /// the zero address remain unrestricted.
  function _update(
    address to,
    uint256 tokenId,
    address auth
  ) internal override returns (address) {
    address from = _ownerOf(tokenId);

    // Allow unrestricted minting (from == address(0)), but for any transfer
    // between non-zero addresses require that the caller is the contract owner.
    if (from != address(0)) {
      require(msg.sender == owner(), "PositionNFT: transfers restricted to owner");
    }

    return super._update(to, tokenId, auth);
  }
}
