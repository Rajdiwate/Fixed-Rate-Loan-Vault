// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {VaultStructs} from "../fixedRateLoanVault/VaultStructs.sol";

/// @notice Vault deployment entrypoints for the controller.
interface IVaultControllerDeployment {
  /// @notice Deploy a new fixed-rate vault instance for the given institution.
  function createVault(
    VaultStructs.VaultConfig memory vaultConfig,
    uint256 collateralFactorMantissa,
    uint256 liquidationThresholdMantissa,
    string memory name_,
    string memory symbol_,
    address institution,
    uint256 requiredInitialCollateral,
    address liquidationAdapter
  ) external returns (address);

  /// @notice Predict the address for a vault that would be created for the given inputs.
  /// @dev Implementation uses CREATE2 deterministic deployment with the position token ID as the salt.
  function predictVaultAddress(
    uint256 positionTokenId
  ) external view returns (address);
}

/// @notice Lifecycle-related controller entrypoints for vaults.
interface IVaultControllerLifecycle {
  /// @notice Transition a vault from CollateralDeposited to Open (fundraising).
  /// @dev Callable only by governance via ACM. Should call the vault's openVault().
  function openVault(address vault) external;

  /// @notice Pause or unpause a specific action on a given vault.
  /// @dev Action is encoded as a uint8 to mirror the VaultAction enum in the controller.
  function setVaultActionPaused(
    address vault,
    uint8 action,
    bool paused
  ) external;
}

/// @notice Governance-settable per-vault risk parameters.
interface IVaultControllerRisk {
  /// @notice Update collateral factor for a specific vault.
  /// @dev Implementations should enforce sensible bounds and emit configuration events.
  function setCollateralFactor(address vault, uint256 newCF) external;

  /// @notice Update liquidation threshold for a specific vault.
  function setLiquidationThreshold(address vault, uint256 newLT) external;

  /// @notice Update liquidation incentive (LI) for a specific vault.
  function setLiquidationIncentive(uint256 newLI) external;

  /// @notice Update close factor for a specific vault.
  function setCloseFactor(uint256 newCloseFactor) external;

  function setProtocolLiquidationShare(uint256 share) external;
}

/// @notice Hooks called by vaults before changing risk (deposit/borrow/repay/withdraw).
interface IVaultControllerRiskHooks {
  /// @notice Validate whether a borrow is allowed for the given vault and amount.
  function borrowAllowed(address vault, uint256 borrowAmount) external view;

  /// @notice Validate whether a collateral withdrawal is allowed.
  function withdrawAllowed(address vault, uint256 withdrawAmount) external view;

  /// @notice Validate a liquidation and compute collateral seize amount.
  function liquidateAllowed(
    address vault,
    uint256 repayAmount
  ) external returns (uint256 seizeAmount);
}

/// @notice Liquidity and shortfall views exposed by the controller.
interface IVaultControllerLiquidity {
  /// @notice Return current liquidity / shortfall for a given vault.
  function getAccountLiquidity(
    address vault
  ) external view returns (uint256 liquidity, uint256 shortfall);

  /// @notice Return hypothetical liquidity / shortfall for a borrow/withdraw scenario.
  /// @param borrowUSD Borrow amount denominated in USD mantissa.
  /// @param withdrawUSD Withdraw amount denominated in USD mantissa.
  function getHypotheticalAccountLiquidity(
    address vault,
    uint256 borrowUSD,
    uint256 withdrawUSD
  ) external view returns (uint256, uint256);

  /// @notice Return the current liquidation shortfall for a vault, if any.
  function getLiquidationShortfall(
    address vault
  ) external view returns (uint256);
}

/// @notice Protocol treasury entrypoints for the controller.
interface IVaultControllerProtocolTreasury {
  /// @notice Returns the address of the protocol treasury.
  function protocolTreasury() external view returns (address);
}

/// @notice Central orchestrator for the institutional fixed-rate vault system.
interface IVaultController is
  IVaultControllerDeployment,
  IVaultControllerLifecycle,
  IVaultControllerRisk,
  IVaultControllerRiskHooks
{
  // --- Events ---

  event VaultCreated(
    address indexed vault,
    address indexed institution,
    uint256 indexed positionTokenId
  );

  event VaultActionPaused(
    address indexed vault,
    uint8 indexed action,
    bool paused
  );

  event CollateralFactorUpdated(address indexed vault, uint256 newCF);

  event LiquidationThresholdUpdated(address indexed vault, uint256 newLT);

  event LiquidationIncentiveUpdated(uint256 newLI);

  event CloseFactorUpdated(uint256 newCloseFactor);

  event OverdueLiquidationEnabled(address indexed vault);

  /// @notice Emitted when the protocol liquidation share is updated.
  event ProtocolLiquidationShareUpdated(uint256 newShare);

  /// @notice Initialize the controller with the Access Control Manager.
  function initialize(
    address acm,
    address oracle,
    address positionNFT,
    uint256 closeFactorMantissa,
    uint256 liquidationIncentiveMantissa,
    address protocolTreasury,
    uint256 protocolLiquidationShare
  ) external;

  /// @notice Set the LoanVault implementation used for minimal proxy clones.
  /// @dev Restricted by ACM in the concrete implementation.
  function setLoanvaultImplementation(address implementation) external;

  // --- Vault Registry ---

  /// @notice Returns true if the given address is a known vault deployed by this controller.
  function isRegistered(address vault) external view returns (bool);

  function setVaultActionPaused(
    address vault,
    uint8 action,
    bool paused
  ) external;
}
