// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {ILiquidationAdapter} from "./ILiquidationAdapter.sol";
import {AccessControlledV8} from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";
import {IFixedRateLoanVault} from "../fixedRateLoanVault/IFixedRateLoanVault.sol";
import {VaultStructs} from "../fixedRateLoanVault/VaultStructs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {VaultControllerStorage} from "../vaultController/VaultControllerStorage.sol";

/// @dev Minimal interface for reading the collateral asset from a vault
interface ICollateralAsset {
  function collateralAsset() external view returns (address);
}

/// @notice Implementation for the LiquidationAdapter contract.
contract LiquidationAdapter is
  AccessControlledV8,
  ILiquidationAdapter,
  ReentrancyGuardUpgradeable,
  VaultStructs
{
  /// @notice Whitelist of approved liquidators.
  mapping(address => bool) public liquidatorWhitelist;

  /// @notice Address that receives the protocol's share of seized collateral.
  address public controller;

  constructor() {
    _disableInitializers();
  }

  modifier onlyWhitelisted() {
    require(liquidatorWhitelist[msg.sender], "not whitelisted");
    _;
  }

  function initialize(address controller_, address acm) external initializer {
    require(controller_ != address(0), "LiquidationAdapter: controller is 0");
    __AccessControlled_init(acm);
    __ReentrancyGuard_init();
    controller = controller_;
  }

  // --- ILiquidationAdapter implementation skeleton ---

  function liquidate(
    address vault,
    uint256 repayAmount
  ) external override onlyWhitelisted nonReentrant {
    (, bool isVaultRegistered, , ) = VaultControllerStorage(controller).vaults(
      vault
    );
    require(isVaultRegistered, "LiquidationAdapter: vault is not registered");
    address protocolTreasury = VaultControllerStorage(controller)
      .protocolTreasury();
    uint256 protocolLiquidationShare = VaultControllerStorage(controller)
      .protocolLiquidationShare();
    // pull the supply asset from the liquidator
    address supplyAsset = IFixedRateLoanVault(address(vault)).supplyAsset();
    uint256 debtAmount = IFixedRateLoanVault(address(vault))
      .outstandingRepayment();

    if (repayAmount > debtAmount) {
      repayAmount = debtAmount;
    }

    bool success = IERC20(supplyAsset).transferFrom(
      msg.sender,
      vault,
      repayAmount
    );
    require(success, "LiquidationAdapter: supply asset transfer failed");

    // Call into the vault to perform liquidation; vault handles risk checks
    // via the controller and returns the actual seized collateral amount.
    uint256 seizeAmount = IFixedRateLoanVault(vault).liquidate(repayAmount);

    // split the seized collateral between the liquidator and the protocol
    uint256 protocolShare = (seizeAmount * protocolLiquidationShare) / 1e18;
    uint256 liquidatorShare = seizeAmount - protocolShare;

    address collateralToken = ICollateralAsset(vault).collateralAsset();

    // transfer the seized collateral to the liquidator
    success = IERC20(collateralToken).transfer(msg.sender, liquidatorShare);
    require(success, "LiquidationAdapter: collateral transfer failed");

    if (protocolShare > 0) {
      // transfer the seized collateral to the protocol treasury
      success = IERC20(collateralToken).transfer(
        protocolTreasury,
        protocolShare
      );
      require(success, "LiquidationAdapter: collateral transfer failed");
    }

    emit LiquidationRouted(
      vault,
      msg.sender,
      repayAmount,
      seizeAmount,
      protocolShare,
      liquidatorShare
    );
  }

  function setLiquidatorWhitelist(address liquidator, bool approved) external {
    _checkAccessAllowed("setLiquidatorWhitelist(address,bool)");
    liquidatorWhitelist[liquidator] = approved;
    emit LiquidatorWhitelistUpdated(liquidator, approved);
  }

  function isWhitelistedLiquidator(
    address account
  ) external view returns (bool) {
    return liquidatorWhitelist[account];
  }
}
