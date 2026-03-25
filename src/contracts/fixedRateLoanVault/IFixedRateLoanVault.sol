// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {VaultStructs} from "./VaultStructs.sol";
import {IVaultController} from "../vaultController/IVaultController.sol";
import {IPositionNFT} from "../positionalNft/IPositionNFT.sol";
import {ILoanVault} from "../loanVaultBase/ILoanVault.sol";

/// @notice Interface for the collateralized fixed-rate institutional vault.
interface IFixedRateLoanVault is ILoanVault, VaultStructs {
  // --- Events specific to the collateralized vault ---

  event CollateralDeposited(uint256 amount);

  event CollateralWithdrawn(uint256 amount);

  event ShortfallDetected(uint256 totalOwed, uint256 available);

  event LiquidationExecuted(
    address indexed liquidator,
    uint256 repayAmount,
    uint256 collateralSeized
  );

  event OverdueLiquidationEnabled(address indexed vault, bool automatic);

  event GovernanceSeizeAndRepay(
    address indexed vault,
    uint256 collateralSeized,
    uint256 debtRepaid,
    uint256 penaltyAmount
  );

  event LatePenaltyApplied(uint256 penaltyAmount);

  // --- Initialization ---

  function initialize(
    VaultConfig memory vaultConfig_,
    IVaultController vaultController_,
    IPositionNFT positionNFT_,
    uint256 positionTokenId_,
    uint256 requiredInitialCollateral,
    string memory name_,
    string memory symbol_,
    address liquidationAdapter
  ) external;

  // --- Lifecycle (operator / controller) ---

  function openVault() external;

  // --- Institution functions (collateral & borrowing) ---

  function depositCollateral(uint256 amount) external;

  function withdrawCollateral(uint256 amount) external;

  function addCollateral(uint256 amount) external;

  function borrow(uint256 amount) external;

  function repay(uint256 amount) external;

  function closeFull() external;

  // --- Liquidation entrypoint (adapter only) ---

  function liquidate(uint256 repayAmount) external returns (uint256);

  function outstandingRepayment() external view returns (uint256);
}
