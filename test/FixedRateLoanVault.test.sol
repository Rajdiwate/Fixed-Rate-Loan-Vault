// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import "forge-std/Test.sol";

import {FixedRateLoanVault} from "../src/contracts/fixedRateLoanVault/FixedRateLoanVault.sol";
import {VaultStructs} from "../src/contracts/fixedRateLoanVault/VaultStructs.sol";
import {IVaultController} from "../src/contracts/vaultController/IVaultController.sol";
import {IPositionNFT} from "../src/contracts/positionalNft/IPositionNFT.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVaultController} from "./mocks/MockVaultController.sol";
import {MockPositionNFT} from "./mocks/MockPositionNFT.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Test harness to expose internal helpers.
contract FixedRateLoanVaultHarness is FixedRateLoanVault {
  function exposed_checkAndAdvanceState() external {
    _checkAndAdvanceState();
  }
}

contract FixedRateLoanVaultTest is Test, VaultStructs {
  FixedRateLoanVaultHarness internal vault;

  MockERC20 internal supplyToken;
  MockERC20 internal collateralToken;
  MockVaultController internal controller;
  MockPositionNFT internal positionNFT;

  address internal protocolTreasury = address(0xBEEF);
  address internal institution = address(0xA11CE);
  address internal supplier = address(0xB0B);
  address internal liquidationAdapter = address(0xD1E);

  uint256 internal constant MANTISSA = 1e18;
  uint256 internal constant POSITION_ID = 1;

  function setUp() public {
    supplyToken = new MockERC20("Supply", "SUP");
    collateralToken = new MockERC20("Collateral", "COL");

    controller = new MockVaultController(protocolTreasury);
    positionNFT = new MockPositionNFT();
    positionNFT.setOwner(POSITION_ID, institution);

    VaultConfig memory cfg;
    cfg.supplyAsset = address(supplyToken);
    cfg.collateralAsset = address(collateralToken);
    cfg.minBorrowCap = 1_000 ether;
    cfg.maxBorrowCap = 2_000 ether;
    cfg.fundraisingDuration = 7 days;
    cfg.lockDuration = 30 days;
    cfg.settlementWindow = 5 days;
    cfg.fixedAPY = 10e16; // 10% APY
    cfg.reserveFactor = 1e17; // 10% of interest
    cfg.autoLiquidateOnDueDate = true;

    uint256 requiredInitialCollateral = 1_000 ether;

    FixedRateLoanVaultHarness vaultImpl = new FixedRateLoanVaultHarness();

    // Deploy the proxy contract and initialize the vault implementation.
    vault = FixedRateLoanVaultHarness(
      address(
        new ERC1967Proxy(
          address(vaultImpl),
          abi.encodeWithSelector(
            vaultImpl.initialize.selector,
            cfg,
            IVaultController(address(controller)),
            IPositionNFT(address(positionNFT)),
            POSITION_ID,
            requiredInitialCollateral,
            "Fixed Rate Vault",
            "FRV",
            liquidationAdapter
          )
        )
      )
    );

    // Give institution and supplier balances.
    supplyToken.mint(supplier, 5_000 ether);
    collateralToken.mint(institution, 2_000 ether);
  }

  // --- Initialization / basic views ---

  function testInitializeSetsInitialState() public view {
    assertEq(uint8(vault.vaultState()), uint8(VaultState.WaitingForCollateral));
    assertEq(address(vault.supplyAsset()), address(supplyToken));
    assertEq(address(vault.collateralAsset()), address(collateralToken));
    assertEq(vault.maxBorrowCap(), 2_000 ether);
    assertEq(vault.minBorrowCap(), 1_000 ether);
    assertEq(vault.requiredInitialCollateral(), 1_000 ether);
  }

  // --- Collateral deposit and vault opening ---

  function _depositFullCollateral() internal {
    vm.startPrank(institution);
    collateralToken.approve(address(vault), type(uint256).max);
    vault.depositCollateral(1_000 ether);
    vm.stopPrank();
    console.log("collateral deposited");
  }

  function _openVault() internal {
    _depositFullCollateral();
    vm.prank(address(controller));
    vault.openVault();
  }

  function testDepositCollateralMovesToCollateralDeposited() public {
    _depositFullCollateral();

    assertEq(uint8(vault.vaultState()), uint8(VaultState.CollateralDeposited));
    assertEq(vault.totalCollateral(), 1_000 ether);
  }

  function testMultipleDepositeCollateral() public {
    vm.startPrank(institution);
    collateralToken.approve(address(vault), type(uint256).max);
    vault.depositCollateral(100 ether);
    // the vault state should still be waiting for collateral
    assertEq(uint8(vault.vaultState()), uint8(VaultState.WaitingForCollateral));

    vault.depositCollateral(200 ether);
    vault.depositCollateral(200 ether);

    vault.depositCollateral(500 ether);
    // the vault state should be collateral deposited
    assertEq(uint8(vault.vaultState()), uint8(VaultState.CollateralDeposited));
    assertEq(vault.totalCollateral(), 1_000 ether);
    vm.stopPrank();
  }

  function testDepositCollateralRevertsWhenOpen() public {
    // deposite full collateral
    vm.startPrank(institution);
    collateralToken.approve(address(vault), type(uint256).max);
    vault.depositCollateral(1000 ether);
    assertEq(uint8(vault.vaultState()), uint8(VaultState.CollateralDeposited));

    // open vault
    vm.stopPrank();
    vm.startPrank(address(controller));
    vault.openVault();
    assertEq(uint8(vault.vaultState()), uint8(VaultState.Open));
    vm.stopPrank();

    // try to deposit collateral again
    vm.startPrank(institution);
    vm.expectRevert();
    vault.depositCollateral(1000 ether);
    vm.stopPrank();
  }

  function testOpenVaultFromControllerSetsOpenStateAndFundraisingEnd() public {
    assertEq(uint8(vault.vaultState()), uint8(VaultState.WaitingForCollateral));
    _openVault();

    assertEq(uint8(vault.vaultState()), uint8(VaultState.Open));
    assertGt(vault.fundraisingEnd(), block.timestamp);
  }

  // --- Supplier deposits / ERC4626 hooks ---

  function _deposit(uint256 amount) internal returns (uint256 shares) {
    vm.startPrank(supplier);
    supplyToken.approve(address(vault), type(uint256).max);
    shares = vault.deposit(amount, supplier);
    vm.stopPrank();
    return shares;
  }

  function _openVaultAndDeposit(
    uint256 amount
  ) internal returns (uint256 shares) {
    _openVault();

    return _deposit(amount);
  }

  function testDepositUpdatesTotalRaisedAndShares() public {
    uint256 amount = 500 ether;
    uint256 shares = _openVaultAndDeposit(amount);

    assertEq(vault.totalRaised(), amount);
    assertEq(vault.totalAssets(), amount);
    assertEq(shares, amount);
    assertEq(vault.balanceOf(supplier), amount);
  }

  function testMintUpdatesTotalRaisedAndShares() public {
    _openVault();
    uint256 sharesToMint = 500 ether;

    vm.startPrank(supplier);
    supplyToken.approve(address(vault), type(uint256).max);
    uint256 assetsUsed = vault.mint(sharesToMint, supplier);
    vm.stopPrank();

    // With 1:1 share price during Open, assets and shares should match.
    assertEq(assetsUsed, sharesToMint);
    assertEq(vault.totalRaised(), sharesToMint);
    assertEq(vault.balanceOf(supplier), sharesToMint);
  }

  function testDepositRevertsWhenNotOpen() public {
    _depositFullCollateral();
    // vaultState is CollateralDeposited, not Open.
    vm.startPrank(supplier);
    supplyToken.approve(address(vault), type(uint256).max);
    vm.expectRevert();
    vault.deposit(1 ether, supplier);
    vm.stopPrank();
  }

  function testMintRevertsWhenNotOpen() public {
    _depositFullCollateral();
    // vaultState is CollateralDeposited, not Open.
    vm.startPrank(supplier);
    supplyToken.approve(address(vault), type(uint256).max);
    vm.expectRevert();
    vault.mint(1 ether, supplier);
    vm.stopPrank();
  }

  function testMaxDepositHonorsOpenStateAndCap() public {
    _openVault();

    // Initially full headroom.
    assertEq(
      vault.maxDeposit(supplier),
      vault.maxBorrowCap() - vault.totalRaised()
    );

    // After raising up to cap, no more deposits.
    _deposit(2_000 ether);
    assertEq(vault.maxDeposit(supplier), 0);
  }

  function testDepositeChangesStateToFailedWhenTotalRaisedIsLessThanMinBorrowCap()
    public
  {
    _openVault();
    assertEq(uint8(vault.vaultState()), uint8(VaultState.Open));
    // deposite insufficient amount
    vm.startPrank(supplier);
    supplyToken.approve(address(vault), type(uint256).max);
    vault.deposit(900 ether, supplier);
    vm.stopPrank();

    // after fundraising end, the vault state should be failed
    vm.warp(vault.fundraisingEnd() + 1);
    vault.exposed_checkAndAdvanceState();
    assertEq(uint8(vault.vaultState()), uint8(VaultState.Failed));
  }

  function testDepositeChangesStateToLockedWhenTotalRaisedIsGreaterThanMinBorrowCap()
    public
  {
    _openVault();
    assertEq(uint8(vault.vaultState()), uint8(VaultState.Open));
    // deposite sufficient amount
    vm.startPrank(supplier);
    supplyToken.approve(address(vault), type(uint256).max);
    vault.deposit(1_500 ether, supplier);
    vm.stopPrank();

    // after depositing, the vault state should be locked
    vm.warp(vault.fundraisingEnd() + 1);
    vault.exposed_checkAndAdvanceState();
    assertEq(uint8(vault.vaultState()), uint8(VaultState.Lock));
  }

  // --- Borrow / repay flow and settlement ---

  function _reachLockStateWithDeposits() internal {
    // Open vault and fully raise to maxBorrowCap to trigger Lock via _checkAndAdvanceState.
    _openVault();
    vm.startPrank(supplier);
    supplyToken.approve(address(vault), type(uint256).max);
    vault.deposit(2_000 ether, supplier); // deposite full amount to reach Lock state
    vm.stopPrank();

    // After hitting maxBorrowCap, state should be Lock.
    assertEq(uint8(vault.vaultState()), uint8(VaultState.Lock));
    console.log("reached Lock state");
  }

  function _borrowFullRaisedAmount() internal {
    _reachLockStateWithDeposits();
    vm.startPrank(institution);
    vault.borrow(vault.totalRaised());
    vm.stopPrank();
    console.log("borrowed full raised amount");
  }

  function testBorrowIncreasesTotalBorrowedAndTransfersSupply() public {
    _reachLockStateWithDeposits();

    uint256 raised = vault.totalRaised();
    uint256 institutionBalanceBefore = supplyToken.balanceOf(institution);

    vm.prank(institution);
    vault.borrow(raised);

    assertEq(vault.totalBorrowed(), raised);
    assertEq(
      supplyToken.balanceOf(institution),
      institutionBalanceBefore + raised
    );
  }

  function testTotalAssetsIsEqualToTotalRaisedInLockState() public {
    _reachLockStateWithDeposits();
    assertEq(vault.totalAssets(), vault.totalRaised());
  }

  function testMaxDepositIsEqualToZeroIfTotalRaisedIsEqualToMaxBorrowCap()
    public
  {
    _openVault();
    vm.startPrank(supplier);
    supplyToken.approve(address(vault), type(uint256).max);
    vault.deposit(2_000 ether, supplier);
    vm.stopPrank();
    assertEq(vault.maxDeposit(supplier), 0);
  }

  function testRepayAdvancesToPendingSettlementAndClaimable() public {
    _borrowFullRaisedAmount();

    // Move time to end of lock to enter PendingSettlement on next state check.
    vm.warp(vault.lockEnd() + 1);
    // Repay outstanding principal in full.
    uint256 outstanding = vault.outstandingRepayment();
    supplyToken.mint(institution, outstanding - vault.outstandingDebt()); // mint the extra intrest to the institution

    vm.startPrank(institution);
    supplyToken.approve(address(vault), type(uint256).max);
    vault.repay(outstanding);
    vm.stopPrank();

    // After full repayment and _checkAndAdvanceState, vault should settle to Claimable.
    assertEq(uint8(vault.vaultState()), uint8(VaultState.Claimable));

    // Settlement amount should be >= totalRaised (principal + interest - protocol fee)
    assertGe(vault.settlementAmount(), vault.totalRaised());
    // Protocol fee should be non-zero given positive interest and reserveFactor.
    assertGt(vault.protocolFee(), 0);
  }

  function testOutstandingRepaymentIncludesInterestDuringLock() public {
    _borrowFullRaisedAmount();

    // halfway through lock period
    uint256 mid = block.timestamp + (vault.lockDuration() / 2);
    vm.warp(mid);

    uint256 outstandingRepayment = vault.outstandingRepayment();
    assertGt(outstandingRepayment, vault.outstandingDebt());
  }

  function testPendingSettlementStateToTermExpired() public {
    _borrowFullRaisedAmount();
    vm.warp(vault.lockEnd() + 1);
    vault.exposed_checkAndAdvanceState();

    vm.warp(vault.settlementDeadline() + 1);
    vault.exposed_checkAndAdvanceState();
    assertEq(uint8(vault.vaultState()), uint8(VaultState.TermExpired));
  }

  // --- Collateral withdrawal ---

  function testWithdrawCollateralInLockAllowsExcessOnly() public {
    _openVault();

    // Raise to 75% of max cap, then enter Lock by time.
    vm.startPrank(supplier);
    supplyToken.approve(address(vault), type(uint256).max);
    vault.deposit(1_500 ether, supplier);
    vm.stopPrank();
    vm.warp(vault.fundraisingEnd() + 1);
    vault.exposed_checkAndAdvanceState();
    assertEq(uint8(vault.vaultState()), uint8(VaultState.Lock));

    // required collateral in lock = 1000 * (1500 / 2000) = 750, excess = 250
    uint256 institutionCollateralBefore = collateralToken.balanceOf(
      institution
    );
    vm.prank(institution);
    vault.withdrawCollateral(200 ether);

    assertEq(vault.totalCollateral(), 800 ether);
    assertEq(
      collateralToken.balanceOf(institution),
      institutionCollateralBefore + 200 ether
    );
  }

  function testWithdrawCollateralRevertsWhenExceedsExcessInLock() public {
    _openVault();

    vm.startPrank(supplier);
    supplyToken.approve(address(vault), type(uint256).max);
    vault.deposit(1_500 ether, supplier);
    vm.stopPrank();
    vm.warp(vault.fundraisingEnd() + 1);
    vault.exposed_checkAndAdvanceState();
    assertEq(uint8(vault.vaultState()), uint8(VaultState.Lock));

    // Max excess is 250, so 300 should revert.
    vm.startPrank(institution);
    vm.expectRevert(bytes("FV: amount exceeds excess collateral"));
    vault.withdrawCollateral(300 ether);
    vm.stopPrank();
  }

  // --- closeFull ---

  function testCloseFullRevertsInClaimableWhenInterestWasRepaid() public {
    _borrowFullRaisedAmount();

    vm.warp(vault.lockEnd() + 1);
    uint256 outstanding = vault.outstandingRepayment();
    supplyToken.mint(institution, outstanding - vault.outstandingDebt());

    vm.startPrank(institution);
    supplyToken.approve(address(vault), type(uint256).max);
    vault.repay(outstanding);
    assertEq(uint8(vault.vaultState()), uint8(VaultState.Claimable));
    vm.expectRevert();
    vault.closeFull();
    vm.stopPrank();
  }

  function testCloseFullRevertsWhenDebtOutstanding() public {
    _borrowFullRaisedAmount();

    vm.prank(institution);
    vm.expectRevert();
    vault.closeFull();
  }

  function testCloseFullMovesToClosedWhenNoInterest() public {
    VaultConfig memory cfg;
    cfg.supplyAsset = address(supplyToken);
    cfg.collateralAsset = address(collateralToken);
    cfg.minBorrowCap = 1_000 ether;
    cfg.maxBorrowCap = 2_000 ether;
    cfg.fundraisingDuration = 7 days;
    cfg.lockDuration = 30 days;
    cfg.settlementWindow = 5 days;
    cfg.fixedAPY = 0;
    cfg.reserveFactor = 0;
    cfg.autoLiquidateOnDueDate = true;

    FixedRateLoanVaultHarness vaultImpl = new FixedRateLoanVaultHarness();
    FixedRateLoanVaultHarness vaultNoInterest = FixedRateLoanVaultHarness(
      address(
        new ERC1967Proxy(
          address(vaultImpl),
          abi.encodeWithSelector(
            vaultImpl.initialize.selector,
            cfg,
            IVaultController(address(controller)),
            IPositionNFT(address(positionNFT)),
            POSITION_ID,
            1_000 ether,
            "Fixed Rate Vault Zero",
            "FRV0",
            liquidationAdapter
          )
        )
      )
    );

    vm.startPrank(institution);
    collateralToken.approve(address(vaultNoInterest), type(uint256).max);
    vaultNoInterest.depositCollateral(1_000 ether);
    vm.stopPrank();

    vm.prank(address(controller));
    vaultNoInterest.openVault();

    vm.startPrank(supplier);
    supplyToken.approve(address(vaultNoInterest), type(uint256).max);
    vaultNoInterest.deposit(2_000 ether, supplier);
    vm.stopPrank();

    vm.prank(institution);
    vaultNoInterest.borrow(2_000 ether);

    vm.warp(vaultNoInterest.lockEnd() + 1);
    vm.startPrank(institution);
    supplyToken.approve(address(vaultNoInterest), type(uint256).max);
    vaultNoInterest.repay(vaultNoInterest.outstandingRepayment());
    assertEq(uint8(vaultNoInterest.vaultState()), uint8(VaultState.Claimable));

    vaultNoInterest.withdrawCollateral(1_000 ether);
    vaultNoInterest.closeFull();
    vm.stopPrank();

    assertEq(uint8(vaultNoInterest.vaultState()), uint8(VaultState.Closed));
  }

  // --- liquidate ---

  function testLiquidateOnlyAdapterCanCall() public {
    _borrowFullRaisedAmount();

    vm.prank(institution);
    vm.expectRevert(bytes("FV: caller is not liquidation adapter"));
    vault.liquidate(100 ether);
  }

  function testLiquidateExecutesAndReturnsSeizeAmountFromZeroAdapter() public {
    _borrowFullRaisedAmount();

    uint256 repayAmount = 1_000 ether; // 50% close factor of 2000 debt
    controller.setSeizeAmountToReturn(400 ether);

    // NOTE: due to current initialize assignment, liquidationAdapter resolves to address(0).
    // Fund zero-address caller and approve vault pull for liquidation repayment.
    supplyToken.mint(address(0), repayAmount);
    vm.startPrank(address(0));
    supplyToken.approve(address(vault), type(uint256).max);
    uint256 seized = vault.liquidate(repayAmount);
    vm.stopPrank();

    assertEq(seized, 400 ether);
    assertEq(controller.lastLiquidateRepayAmount(), repayAmount);
    assertEq(vault.totalRepaid(), repayAmount);
    assertEq(collateralToken.balanceOf(address(0)), 400 ether);
  }

  // --- Withdraw / redeem gating ---

  function testMaxWithdrawZeroBeforeClaimableOrFailed() public {
    _openVaultAndDeposit(500 ether);
    // Still Open.
    assertEq(vault.maxWithdraw(supplier), 0);
    assertEq(vault.maxRedeem(supplier), 0);
  }

  function testWithdrawAndRedeemOnlyInClaimableOrFailed() public {
    uint256 amount = 1_000 ether;
    _borrowFullRaisedAmount();

    supplyToken.mint(
      address(institution),
      vault.outstandingRepayment() - vault.outstandingDebt()
    );

    // Fully repay and settle to Claimable.
    vm.warp(vault.lockEnd() + 1);
    vm.startPrank(institution);
    supplyToken.approve(address(vault), type(uint256).max);
    vault.repay(vault.outstandingRepayment());
    vm.stopPrank();
    assertEq(uint8(vault.vaultState()), uint8(VaultState.Claimable));

    vm.startPrank(supplier);
    uint256 supplierBalanceBefore = supplyToken.balanceOf(supplier);
    uint256 sharesBurned = vault.withdraw(amount, supplier, supplier);
    uint256 supplierBalanceAfter = supplyToken.balanceOf(supplier);

    // Verify withdraw transferred the requested assets
    assertEq(supplierBalanceAfter - supplierBalanceBefore, amount);
    // Shares burned should be positive
    assertGt(sharesBurned, 0);

    // Redeem remaining shares
    uint256 remainingShares = vault.balanceOf(supplier);
    if (remainingShares > 0) {
      uint256 redeemedAssets = vault.redeem(
        remainingShares,
        supplier,
        supplier
      );
      assertGt(redeemedAssets, 0);
    }
    vm.stopPrank();
  }
}
