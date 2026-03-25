// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/// @notice Interface for the shared BaseVault (ERC-4626 + config + interest helper).
interface ILoanVault {
  function calculateExpectedInterest(
    uint256 principal,
    uint256 duration
  ) external view returns (uint256);

  function outstandingDebt() external view returns (uint256);

  function supplyAsset() external view returns (address);
}
