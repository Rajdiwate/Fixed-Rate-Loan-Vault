// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {VaultStructs} from "../../src/contracts/fixedRateLoanVault/VaultStructs.sol";

/// @dev Mock vault exposing just the state surface used by VaultController risk hooks.
contract MockRiskStateVault is VaultStructs {
  address public supplyAsset;
  address public collateralAsset;

  uint256 public totalBorrowed;
  uint256 public totalRepaid;
  uint256 public totalRaised;
  uint256 public totalCollateral;
  uint256 public outstandingDebt;

  VaultState public vaultState;

  function setAssets(address supplyAsset_, address collateralAsset_) external {
    supplyAsset = supplyAsset_;
    collateralAsset = collateralAsset_;
  }

  function setTotals(
    uint256 totalBorrowed_,
    uint256 totalRepaid_,
    uint256 totalRaised_,
    uint256 totalCollateral_,
    uint256 outstandingDebt_
  ) external {
    totalBorrowed = totalBorrowed_;
    totalRepaid = totalRepaid_;
    totalRaised = totalRaised_;
    totalCollateral = totalCollateral_;
    outstandingDebt = outstandingDebt_;
  }
}
