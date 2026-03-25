// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/// @notice Interface for the dedicated liquidation adapter contract.
interface ILiquidationAdapter {
  // --- Events ---

  /// @notice Emitted when a liquidation is executed via the adapter.
  event LiquidationRouted(
    address indexed vault,
    address indexed liquidator,
    uint256 repayAmount,
    uint256 collateralSeized,
    uint256 protocolShare,
    uint256 liquidatorShare
  );

  /// @notice Emitted when the liquidator whitelist is updated.
  event LiquidatorWhitelistUpdated(address indexed liquidator, bool approved);

  /// @notice Route a liquidation to a specific vault.
  function liquidate(address vault, uint256 repayAmount) external;

  /// @notice Add or remove an address from the liquidator whitelist.
  /// @dev Governance-gated via ACM.
  function setLiquidatorWhitelist(address liquidator, bool approved) external;

  /// @notice Returns true if the given address is currently whitelisted as a liquidator.
  function isWhitelistedLiquidator(address) external view returns (bool);
}
