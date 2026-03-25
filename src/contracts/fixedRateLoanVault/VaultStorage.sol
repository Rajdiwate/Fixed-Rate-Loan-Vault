// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {VaultStructs} from "./VaultStructs.sol";
import {IPositionNFT} from "../positionalNft/IPositionNFT.sol";
import {IVaultController} from "../vaultController/IVaultController.sol";

/// @notice Storage specific to the collateralized / liquidation-aware vault.
abstract contract VaultStorage is VaultStructs {
  // Addresses and identifiers that tie this vault to controller and position NFT
  IVaultController public vaultController;
  IPositionNFT public positionNFT;
  uint256 public positionTokenId;

  address public collateralAsset; // ERC20 collateral posted by the institution
  uint256 public fundraisingDuration; // duration of the fundraising period
  uint256 public fundraisingEnd; // timestamp when fundraising ends
  uint256 public lockStart; // timestamp when Lock starts
  uint256 public lockEnd; // timestamp when Lock ends
  uint256 public lockDuration; // duration of the lock period
  uint256 public settlementWindow; // duration of the settlement window
  uint256 public settlementDeadline; // latest timestamp for repayment before TermExpired

  uint256 public reserveFactor; // protocol reserve factor in 1e18 mantissa
  bool public autoLiquidateOnDueDate; // auto enable overdue liquidation on TermExpired

  VaultState public vaultState;

  address public liquidationAdapter;

  uint256 public settlementAmount;
  uint256 public requiredInitialCollateral;
  uint256 public totalCollateral;
  uint256 public protocolFee;
}
