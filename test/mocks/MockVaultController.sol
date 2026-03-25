// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/// @dev Minimal controller mock implementing only the hooks used by the vault.
contract MockVaultController {
  address public protocolTreasury_;

  uint256 public lastLiquidateRepayAmount;
  uint256 public seizeAmountToReturn;

  constructor(address treasury_) {
    protocolTreasury_ = treasury_;
  }

  // --- Risk hooks (no-op / simple behavior) ---

  function supplyDepositAllowed(
    address /*vault*/,
    uint256 /*amount*/
  ) external view {}

  function withdrawAllowed(
    address /*vault*/,
    uint256 /*amount*/
  ) external view {}

  function borrowAllowed(address /*vault*/, uint256 /*amount*/) external view {}

  function depositAllowed(
    address /*vault*/,
    uint256 /*amount*/
  ) external view {}

  function repayAllowed(address /*vault*/, uint256 /*amount*/) external view {}

  function redeemAllowed(address /*vault*/, uint256 /*amount*/) external view {}

  // --- Liquidation hook ---

  function liquidateAllowed(
    address /*vault*/,
    uint256 repayAmount
  ) external returns (uint256) {
    lastLiquidateRepayAmount = repayAmount;
    return seizeAmountToReturn;
  }

  // --- Protocol treasury view used via IVaultControllerProtocolTreasury ---

  function protocolTreasury() external view returns (address) {
    return protocolTreasury_;
  }

  function setSeizeAmountToReturn(uint256 seizeAmount) external {
    seizeAmountToReturn = seizeAmount;
  }
}
