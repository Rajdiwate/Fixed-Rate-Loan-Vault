// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/// @notice Interface for the institution position NFT used to represent vault ownership.
interface IPositionNFT  {
    /// @notice Mint a new position NFT to the given recipient.
    /// @dev Restricted to the VaultController (or other authorized minter) in the implementation.
    /// @return tokenId The newly minted token id.
    function mint(address to) external returns (uint256 tokenId);

    function setVaultController(address vaultController) external;
}

