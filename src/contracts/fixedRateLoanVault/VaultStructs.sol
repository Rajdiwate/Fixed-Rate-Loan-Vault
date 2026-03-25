// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/// @notice Shared enums and struct types for the institutional fixed-rate vault system.
interface VaultStructs {
  /// @notice High-level lifecycle state for a LoanVault.
  enum VaultState {
    WaitingForCollateral, // 0 — deployed, awaiting institution collateral
    CollateralDeposited, // 1 — collateral received, awaiting open trigger
    Open, // 2 — fundraising: suppliers deposit supply asset
    Lock, // 3 — borrowing active, interest accruing
    PendingSettlement, // 4 — maturity reached, awaiting repayment within settlement window
    TermExpired, // 5 — settlement deadline passed with outstanding debt; resolution pending
    Claimable, // 6 — settlement confirmed, suppliers can redeem
    Closed, // 7 — terminal: all claims processed
    Failed // 8 — fundraising failed (below min cap)
  }

  /// @notice Configuration set once per vault at creation.
  struct VaultConfig {
    address supplyAsset; // ERC20 asset deposited by suppliers
    address collateralAsset; // ERC20 collateral posted by the institution
    uint256 minBorrowCap; // minimum totalRaised required for vault to succeed
    uint256 maxBorrowCap; // maximum totalRaised / targetBorrow
    uint256 fundraisingDuration; // duration of the fundraising period
    uint256 lockDuration; // duration of the Lock period
    uint256 settlementWindow; // duration of the settlement window
    uint256 fixedAPY; // fixed annual rate in 1e18 mantissa
    uint256 reserveFactor; // protocol reserve factor in 1e18 mantissa
    bool autoLiquidateOnDueDate; // auto enable overdue liquidation on TermExpired
  }
}
