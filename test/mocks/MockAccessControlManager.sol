// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/// @dev Minimal ACM mock used by AccessControlledV8 contracts in tests.
contract MockAccessControlManager {
  function isAllowedToCall(
    address,
    string calldata
  ) external pure returns (bool) {
    return true;
  }
}
