// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/// @dev Minimal oracle mock for VaultController tests.
contract MockOracle {
  mapping(address => uint256) public prices;

  function setPrice(address asset, uint256 price) external {
    prices[asset] = price;
  }

  function getPrice(address asset) external view returns (uint256) {
    return prices[asset];
  }
}
