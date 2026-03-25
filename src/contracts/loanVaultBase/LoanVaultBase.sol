// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {ILoanVault} from "./ILoanVault.sol";
import {VaultStructs} from "../fixedRateLoanVault/VaultStructs.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/// @notice Abstract base vault with shared ERC-4626 + fundraising + interest + settlement surface.
/// @dev Contains only common pieces so it can be reused by multiple concrete vault types.
abstract contract LoanVaultBase is
  Initializable,
  ERC4626Upgradeable,
  ReentrancyGuardUpgradeable,
  ILoanVault
{
  uint256 private constant YEAR = 365 days;
  uint256 private constant MANTISSA = 1e18;

  // --- Common storage (base vault only) ---
  address public supplyAsset;
  uint256 public fixedAPY;
  uint256 public maxBorrowCap;
  uint256 public minBorrowCap;
  uint256 public totalBorrowed;
  uint256 public totalRepaid;
  uint256 public totalRaised;

  function _checkDepositAllowed() internal view virtual returns (bool);

  function _checkWithdrawAllowed() internal view virtual returns (bool);

  function _totalAssets() internal view virtual returns (uint256);

  function _lockVault() internal virtual;

  function _checkAndAdvanceState() internal virtual;

  /// @notice Initialize the base vault.
  /// @param asset_ The address of the supply asset.
  /// @param name_ The name of the vault.
  /// @param symbol_ The symbol of the vault.
  /// @param maxBorrowCap_ The maximum borrow cap.
  /// @param minBorrowCap_ The minimum borrow cap.
  /// @param fixedAPY_ The fixed APY.
  function __LoanVaultBase_init(
    address asset_,
    string memory name_,
    string memory symbol_,
    uint256 maxBorrowCap_,
    uint256 minBorrowCap_,
    uint256 fixedAPY_
  ) internal onlyInitializing {
    __ERC20_init(name_, symbol_);
    __ERC4626_init(IERC20Upgradeable(asset_));
    __ReentrancyGuard_init();
    supplyAsset = asset_;
    maxBorrowCap = maxBorrowCap_;
    minBorrowCap = minBorrowCap_;
    fixedAPY = fixedAPY_;
    totalBorrowed = 0;
    totalRepaid = 0;
    totalRaised = 0;
  }

  /// @notice Calculate the expected interest for a given principal and duration.
  /// @param principal The principal amount.
  /// @param duration The duration in seconds.
  /// @return The expected interest.
  function calculateExpectedInterest(
    uint256 principal,
    uint256 duration
  ) public view virtual returns (uint256) {
    if (principal == 0) {
      return 0;
    }

    // totalInterest = principal * fixedAPY * lockDuration / YEAR / MANTISSA
    return (principal * fixedAPY * duration) / YEAR / MANTISSA;
  }

  /// @inheritdoc ERC4626Upgradeable
  function maxDeposit(
    address /*receiver*/
  ) public view virtual override returns (uint256) {
    if (!_checkDepositAllowed()) {
      return 0;
    }

    // Cap deposits at the remaining headroom to maxBorrowCap.
    return maxBorrowCap - totalRaised;
  }

  function maxMint(
    address /*receiver*/
  ) public view virtual override returns (uint256) {
    if (!_checkDepositAllowed()) {
      return 0;
    }

    return maxBorrowCap - totalRaised;
  }

  /// @inheritdoc ERC4626Upgradeable
  function maxWithdraw(
    address owner
  ) public view virtual override returns (uint256) {
    if (!_checkWithdrawAllowed()) {
      return 0;
    }

    return super.maxWithdraw(owner);
  }

  /// @inheritdoc ERC4626Upgradeable
  function maxRedeem(
    address owner
  ) public view virtual override returns (uint256) {
    if (!_checkWithdrawAllowed()) {
      return 0;
    }

    return super.maxRedeem(owner);
  }

  function totalAssets() public view virtual override returns (uint256) {
    return _totalAssets();
  }

  /// @notice Deposit assets into the vault.
  /// @param amount The amount of assets to deposit.
  /// @param receiver The address to receive the shares.
  /// @return The amount of shares received.
  function deposit(
    uint256 amount,
    address receiver
  ) public virtual override nonReentrant returns (uint256) {
    _checkAndAdvanceState();
    require(_checkDepositAllowed(), "LoanVaultBase: deposit not allowed");
    require(amount > 0, "LoanVaultBase: amount must be greater than 0");
    require(
      totalRaised + amount <= maxBorrowCap,
      "LoanVaultBase: total raised exceeds max borrow cap"
    );

    uint256 shares = super.deposit(amount, receiver);

    totalRaised += amount;

    if (totalRaised == maxBorrowCap) {
      _lockVault();
    }
    return shares;
  }

  /// @notice Mint shares for a given amount of assets.
  /// @param shares The amount of shares to mint.
  /// @param receiver The address to receive the shares.
  /// @return The amount of shares received.
  function mint(
    uint256 shares,
    address receiver
  ) public virtual override nonReentrant returns (uint256) {
    _checkAndAdvanceState();
    require(_checkDepositAllowed(), "LoanVaultBase: deposit not allowed");
    require(shares > 0, "LoanVaultBase: shares must be greater than 0");
    uint256 assets = previewMint(shares);
    require(
      totalRaised + assets <= maxBorrowCap,
      "LoanVaultBase: total raised exceeds max borrow cap"
    );
    totalRaised += assets; // initially 1:1 ratio between shares and assets

    if (totalRaised == maxBorrowCap) {
      _lockVault();
    }
    return super.mint(shares, receiver);
  }

  function withdraw(
    uint256 amount,
    address receiver,
    address owner
  ) public virtual override nonReentrant returns (uint256) {
    _checkAndAdvanceState();
    require(_checkWithdrawAllowed(), "LoanVaultBase: withdraw not allowed");
    require(amount > 0, "LoanVaultBase: amount must be greater than 0");
    return super.withdraw(amount, receiver, owner);
  }

  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) public virtual override nonReentrant returns (uint256) {
    _checkAndAdvanceState();
    require(_checkWithdrawAllowed(), "LoanVaultBase: withdraw not allowed");
    require(shares > 0, "LoanVaultBase: shares must be greater than 0");
    return super.redeem(shares, receiver, owner);
  }

  function outstandingDebt() public view returns (uint256) {
    if (totalBorrowed > totalRepaid) {
      return totalBorrowed - totalRepaid;
    }
    return 0;
  }
}
