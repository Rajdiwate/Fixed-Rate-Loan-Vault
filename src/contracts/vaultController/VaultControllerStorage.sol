// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {VaultStructs} from "../fixedRateLoanVault/VaultStructs.sol";
import {IPositionNFT} from "../positionalNft/IPositionNFT.sol";
import {IFixedRateLoanVault} from "../fixedRateLoanVault/IFixedRateLoanVault.sol";
import {OracleInterface} from "@venusprotocol/oracle/contracts/interfaces/OracleInterface.sol";

/// @notice Base storage layout for VaultController implementations.
abstract contract VaultControllerStorage is VaultStructs {
  /// @notice Encodes the set of pausable actions for a vault.
  enum VaultAction {
    WITHDRAW, // collateral withdrawal
    BORROW, // institution borrow
    LIQUIDATE // liquidation via adapter
  }

  struct Vault {
    address vault;
    bool isVaultRegistered;
    //  Multiplier representing the most one can borrow against their collateral in this market.
    //  For instance, 0.9 to allow borrowing 90% of collateral value.
    //  Must be between 0 and 1, and stored as a mantissa.
    uint256 collateralFactorMantissa;
    //  Multiplier representing the collateralization after which the borrow is eligible
    //  for liquidation. For instance, 0.8 liquidate when the borrow is 80% of collateral
    //  value. Must be between 0 and collateral factor, stored as a mantissa.
    uint256 liquidationThresholdMantissa;
  }

  // --- Registry ---

  IFixedRateLoanVault[] internal allVaults;
  mapping(address => Vault) public vaults;

  // --- Per-vault action pause controls ---

  /// @notice Per-vault, per-action pause flags.
  mapping(address => mapping(uint8 => bool)) internal vaultActionPaused;

  // --- Configuration mappings ---

  /// @notice Reference to the Venus ResilientOracle used for pricing.
  OracleInterface public resilientOracle;

  /// @notice Reference to the InstitutionPositionNFT contract.
  IPositionNFT public positionNFT;

  /// @notice Reference to the LoanVault implementation used for EIP-1167 clones.
  address public loanVaultImplementation;

  /// @notice Address holding protocol fees.
  address public protocolTreasury;

  /// @notice Close factor mantissa.
  uint256 public closeFactorMantissa;

  /// @notice Liquidation incentive mantissa.
  uint256 public liquidationIncentiveMantissa;

  /// @notice Fraction of liquidation incentive that goes to the protocol, in 1e18 mantissa.
  uint256 public protocolLiquidationShare;
}
