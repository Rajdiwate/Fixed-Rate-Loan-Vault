// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IVaultController} from "../vaultController/IVaultController.sol";
import {IFixedRateLoanVault} from "./IFixedRateLoanVault.sol";
import {IPositionNFT} from "../positionalNft/IPositionNFT.sol";
import {VaultStorage} from "./VaultStorage.sol";
import {LoanVaultBase} from "../loanVaultBase/LoanVaultBase.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVaultControllerProtocolTreasury} from "../vaultController/IVaultController.sol";

/// @notice Fixed-rate institutional LoanVault implementation.
contract FixedRateLoanVault is
  LoanVaultBase,
  IFixedRateLoanVault,
  VaultStorage
{
  event VaultStateUpdated(VaultState previousState, VaultState newState);

  uint256 private constant MANTISSA = 1e18;

  constructor() {
    _disableInitializers();
  }

  modifier onlyInstitution() {
    require(
      msg.sender == IERC721(address(positionNFT)).ownerOf(positionTokenId),
      "FV: not Allowed"
    );
    _;
  }

  modifier onlyController() {
    require(msg.sender == address(vaultController), "FV: not authorized");
    _;
  }

  modifier onlyLiquidationAdapter() {
    require(
      msg.sender == liquidationAdapter,
      "FV: caller is not liquidation adapter"
    );
    _;
  }

  function initialize(
    VaultConfig memory vaultConfig_,
    IVaultController vaultController_,
    IPositionNFT positionNFT_,
    uint256 positionTokenId_,
    uint256 requiredInitialCollateral_,
    string memory name_,
    string memory symbol_,
    address liquidationAdapter
  ) external initializer {
    __LoanVaultBase_init(
      vaultConfig_.supplyAsset,
      name_,
      symbol_,
      vaultConfig_.maxBorrowCap,
      vaultConfig_.minBorrowCap,
      vaultConfig_.fixedAPY
    );

    vaultController = vaultController_;
    positionNFT = positionNFT_;
    positionTokenId = positionTokenId_;
    vaultState = VaultState.WaitingForCollateral;
    protocolFee = 0;
    supplyAsset = vaultConfig_.supplyAsset;
    collateralAsset = vaultConfig_.collateralAsset;
    fundraisingDuration = vaultConfig_.fundraisingDuration;
    lockDuration = vaultConfig_.lockDuration;
    settlementWindow = vaultConfig_.settlementWindow;
    reserveFactor = vaultConfig_.reserveFactor;
    autoLiquidateOnDueDate = vaultConfig_.autoLiquidateOnDueDate;
    requiredInitialCollateral = requiredInitialCollateral_;
    liquidationAdapter = liquidationAdapter;
  }

  function openVault() external onlyController {
    _checkAndAdvanceState();
    require(
      vaultState == VaultState.CollateralDeposited,
      "FV: not in CollateralDeposited state"
    );
    require(
      totalCollateral >= requiredInitialCollateral,
      "FV: total collateral not met required initial collateral"
    );
    _setVaultState(VaultState.Open);
    fundraisingEnd = block.timestamp + fundraisingDuration;
  }

  // --- Institution functions (collateral & borrowing) ---

  function depositCollateral(
    uint256 amount
  ) external onlyInstitution nonReentrant {
    _checkAndAdvanceState();

    require(
      vaultState == VaultState.WaitingForCollateral,
      "FV: not in WaitingForCollateral state"
    );
    require(amount > 0, "FV: amount must be greater than 0");

    require(
      amount + totalCollateral <= requiredInitialCollateral,
      "FV: total collateral exceeds min collateral amount"
    );

    totalCollateral += amount;
    bool success = IERC20(collateralAsset).transferFrom(
      msg.sender,
      address(this),
      amount
    );

    require(success, "FV: collateral transfer failed");

    if (totalCollateral == requiredInitialCollateral) {
      _setVaultState(VaultState.CollateralDeposited);
    }
    emit CollateralDeposited(amount);
  }

  function addCollateral(uint256 amount) external onlyInstitution nonReentrant {
    _checkAndAdvanceState();
    require(vaultState == VaultState.Lock, "FV: not in Lock state");
    require(amount > 0, "FV: amount must be greater than 0");
    totalCollateral += amount;
    bool success = IERC20(collateralAsset).transferFrom(
      msg.sender,
      address(this),
      amount
    );
    require(success, "FV: collateral transfer failed");
    emit CollateralDeposited(amount);
  }

  function withdrawCollateral(
    uint256 amount
  ) external onlyInstitution nonReentrant {
    _checkAndAdvanceState();
    vaultController.withdrawAllowed(address(this), amount);

    // withdraw excess collateral if the vault is locked
    if (vaultState == VaultState.Lock) {
      require(amount > 0, "FV: amount must be greater than 0");

      // Raised Ratio = totalRaised / maxBorrowCap (scaled by MANTISSA)
      uint256 raisedRatio = (totalRaised * MANTISSA) / maxBorrowCap;

      // Remaining collateral requirement = Raised Ratio * Initial Collateral
      uint256 requiredCollateralAfterRaise = (requiredInitialCollateral *
        raisedRatio) / MANTISSA;

      // If current collateral is already at or below required, no excess is available.
      require(
        totalCollateral > requiredCollateralAfterRaise,
        "FV: no excess collateral"
      );

      // Withdrawable excess is the amount above the required collateral.
      uint256 maxWithdrawable = totalCollateral - requiredCollateralAfterRaise;
      require(
        amount <= maxWithdrawable,
        "FV: amount exceeds excess collateral"
      );
    } else {
      require(
        vaultState == VaultState.Closed ||
          vaultState == VaultState.Failed ||
          vaultState == VaultState.Claimable,
        "FV: vault is not closed, failed, or claimable"
      );

      require(
        amount <= totalCollateral,
        "FV: amount must be less than or equal to total collateral"
      );
    }

    totalCollateral -= amount;
    bool success = IERC20(collateralAsset).transfer(msg.sender, amount);

    require(success, "FV: collateral transfer failed");

    emit CollateralWithdrawn(amount);
  }

  function borrow(uint256 amount) external onlyInstitution nonReentrant {
    _checkAndAdvanceState();
    vaultController.borrowAllowed(address(this), amount);

    require(vaultState == VaultState.Lock, "FV: vault not locked");

    // make sure that the sufficient amount has been raised
    require(
      totalBorrowed + amount <= totalRaised,
      "FV: total borrowed exceeds total raised"
    );

    totalBorrowed += amount;
    bool success = IERC20(supplyAsset).transfer(msg.sender, amount);

    require(success, "FV: supply asset transfer failed");
  }

  function repay(uint256 amount) external onlyInstitution nonReentrant {
    _checkAndAdvanceState();

    //  the sate should be lock/pending settlement
    require(
      vaultState == VaultState.Lock ||
        vaultState == VaultState.PendingSettlement ||
        vaultState == VaultState.TermExpired,
      "FV: vault is not locked or pending settlement or term expired"
    );
    // amount should be less than or equal to the outstandingRepayment()
    require(
      amount <= outstandingRepayment(),
      "FV: amount exceeds outstanding debt"
    );
    totalRepaid += amount;

    bool success = IERC20(supplyAsset).transferFrom(
      msg.sender,
      address(this),
      amount
    );
    require(success, "FV: supply asset transfer failed");

    _checkAndAdvanceState();
  }

  function closeFull() external onlyInstitution nonReentrant {
    _checkAndAdvanceState();

    // Allow closing only once the vault has reached the post-repayment phase.
    require(vaultState == VaultState.Claimable, "FV: vault not ready to close");
    require(outstandingRepayment() == 0, "FV: outstanding repayment remains");
    require(totalCollateral == 0, "FV: total collateral is not 0");

    _setVaultState(VaultState.Closed);
  }

  function liquidate(
    uint256 repayAmount
  ) external onlyLiquidationAdapter nonReentrant returns (uint256) {
    _checkAndAdvanceState();

    require(
      vaultState == VaultState.Lock ||
        vaultState == VaultState.PendingSettlement ||
        (vaultState == VaultState.TermExpired && autoLiquidateOnDueDate),
      "FV: invalid state for liquidation"
    );

    // Ask controller to validate and compute seize amount.
    uint256 seizeAmount = vaultController.liquidateAllowed(
      address(this),
      repayAmount
    );
    require(seizeAmount > 0, "FV: zero seize amount");

    // Capture total outstanding debt before applying this liquidation.
    uint256 totalOwedBefore = outstandingRepayment();

    // Update repayment accounting.
    totalRepaid += repayAmount;

    // Cap seizeAmount by available collateral.
    uint256 collateralBalance = IERC20(collateralAsset).balanceOf(
      address(this)
    );
    if (seizeAmount > collateralBalance) {
      seizeAmount = collateralBalance;
    }

    totalCollateral -= seizeAmount;
    // Transfer seized collateral back to the adapter, which will distribute it.
    bool success = IERC20(collateralAsset).transfer(msg.sender, seizeAmount);
    require(success, "FV: collateral transfer failed");

    // If we have exhausted all collateral while some debt may remain,
    // emit a shortfall event to signal under-repayment vs. available assets.
    uint256 availableAfter = IERC20(collateralAsset).balanceOf(address(this));
    if (availableAfter == 0 && totalOwedBefore > repayAmount) {
      emit ShortfallDetected(totalOwedBefore, collateralBalance);
    }

    emit LiquidationExecuted(msg.sender, repayAmount, seizeAmount);

    _checkAndAdvanceState();
    return seizeAmount;
  }

  // --- Views specific to this vault ---

  function outstandingRepayment() public view returns (uint256) {
    // Only meaningful while the loan is active or in the settlement window.
    if (
      vaultState != VaultState.PendingSettlement &&
      vaultState != VaultState.Lock &&
      vaultState != VaultState.TermExpired
    ) {
      return 0;
    }

    uint256 totalInterest = calculateExpectedInterest(
      totalRaised,
      lockDuration
    );
    uint256 totalOwed = totalBorrowed + totalInterest;
    return totalOwed > totalRepaid ? totalOwed - totalRepaid : 0;
  }

  function _settleVault() internal {
    // Settlement occurs when the vault debt becomes zero and the vault is in a
    // post-maturity resolution state (PendingSettlement or TermExpired).
    require(
      vaultState == VaultState.PendingSettlement ||
        vaultState == VaultState.TermExpired,
      "FV: invalid state for settlement"
    );

    // Compute expected fixed-rate interest over the lock period.
    uint256 totalInterest = calculateExpectedInterest(
      totalRaised,
      lockDuration
    );

    uint256 totalOwed = totalBorrowed + totalInterest;
    require(totalRepaid >= totalOwed, "FV: outstanding repayment remains");

    // calculate the protocol fee
    uint256 protocolFee_ = (totalInterest * reserveFactor) / MANTISSA;
    // calculate the user interest
    uint256 supplierInterest = totalInterest > protocolFee_
      ? totalInterest - protocolFee_
      : 0;

    // calculate the settlement amount
    protocolFee = protocolFee_;
    settlementAmount = totalRaised + supplierInterest;

    // Transfer protocol fee to treasury if any balance is available.
    if (protocolFee_ > 0) {
      // Use a minimal interface to read the protocolTreasury address from the controller.
      address treasury = IVaultControllerProtocolTreasury(
        address(vaultController)
      ).protocolTreasury();
      if (treasury != address(0)) {
        bool success = IERC20(supplyAsset).transfer(treasury, protocolFee_);

        require(success, "FV: supply asset transfer failed");
      }
    }

    // Move to the claimable state so suppliers can redeem at the new share price.
    _setVaultState(VaultState.Claimable);
  }

  /// @notice Internal helper to advance vaultState based on time and repayment.
  function _checkAndAdvanceState() internal override {
    VaultState state = vaultState;

    // Open → Lock / Failed
    if (state == VaultState.Open) {
      if (block.timestamp >= fundraisingEnd) {
        if (totalRaised < minBorrowCap) {
          _setVaultState(VaultState.Failed);
        } else {
          // Enter Lock: start lock and compute lockEnd from duration.
          _setVaultState(VaultState.Lock);
          lockStart = block.timestamp;
          lockEnd = block.timestamp + lockDuration;
        }
        return;
      }

      // Early Lock if cap reached
      if (totalRaised >= maxBorrowCap) {
        _setVaultState(VaultState.Lock);
        lockStart = block.timestamp;
        lockEnd = block.timestamp + lockDuration;
        return;
      }
    }

    // Lock → PendingSettlement
    if (state == VaultState.Lock) {
      if (block.timestamp >= lockEnd) {
        // Transition into settlement window: set deadline based on window.
        _setVaultState(VaultState.PendingSettlement);
        settlementDeadline = block.timestamp + settlementWindow;
        return;
      }
    }

    // PendingSettlement → Claimable / TermExpired
    if (state == VaultState.PendingSettlement) {
      uint256 totalInterest = calculateExpectedInterest(
        totalRaised,
        lockDuration
      );
      uint256 totalOwed = totalBorrowed + totalInterest;
      if (totalRepaid >= totalOwed) {
        _settleVault();
        return;
      }

      if (block.timestamp >= settlementDeadline) {
        _setVaultState(VaultState.TermExpired);
        return;
      }
    }

    // TermExpired → Claimable (after full recovery via liquidation)
    if (state == VaultState.TermExpired) {
      uint256 totalInterest = calculateExpectedInterest(
        totalRaised,
        lockDuration
      );
      uint256 totalOwed = totalBorrowed + totalInterest;
      if (totalRepaid >= totalOwed) {
        _settleVault();
        return;
      }
    }
  }

  function _checkDepositAllowed() internal view override returns (bool) {
    return vaultState == VaultState.Open;
  }

  function _checkWithdrawAllowed() internal view override returns (bool) {
    return
      vaultState == VaultState.Claimable || vaultState == VaultState.Failed;
  }

  function _totalAssets() internal view override returns (uint256) {
    VaultState state_ = vaultState;

    // During Lock / PendingSettlement / TermExpired: assets track totalRaised principal.
    if (
      state_ == VaultState.Lock ||
      state_ == VaultState.PendingSettlement ||
      state_ == VaultState.TermExpired
    ) {
      return totalRaised;
    }

    // Before lock (WaitingForCollateral, CollateralDeposited, Open) and Failed:
    // fall back to underlying token balance / standard ERC4626 semantics.
    return IERC20(supplyAsset).balanceOf(address(this));
  }

  function _setVaultState(VaultState newState) internal {
    VaultState previousState = vaultState;
    if (previousState == newState) {
      return;
    }
    vaultState = newState;
    emit VaultStateUpdated(previousState, newState);
  }

  function _lockVault() internal override {
    _setVaultState(VaultState.Lock);
    lockStart = block.timestamp;
    lockEnd = block.timestamp + lockDuration;
  }
}
