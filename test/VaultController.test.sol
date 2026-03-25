// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import "forge-std/Test.sol";

import {VaultController} from "../src/contracts/vaultController/VaultController.sol";
import {FixedRateLoanVault} from "../src/contracts/fixedRateLoanVault/FixedRateLoanVault.sol";
import {IFixedRateLoanVault} from "../src/contracts/fixedRateLoanVault/IFixedRateLoanVault.sol";
import {MockPositionNFT} from "./mocks/MockPositionNFT.sol";
import {MockAccessControlManager} from "./mocks/MockAccessControlManager.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VaultStructs} from "../src/contracts/fixedRateLoanVault/VaultStructs.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultControllerTest is Test, VaultStructs {
  VaultController public vaultController;
  MockOracle public oracle;
  MockPositionNFT public positionNFT;
  MockERC20 public supplyToken;
  MockERC20 public collateralToken;

  address internal institution = address(0xA11CE);
  address internal liquidationAdapter = address(0xD1E);
  address internal protocolTreasury = address(0xBEEF);

  function setUp() public {
    address acm = address(new MockAccessControlManager());
    oracle = new MockOracle();
    positionNFT = new MockPositionNFT();
    supplyToken = new MockERC20("Supply", "SUP");
    collateralToken = new MockERC20("Collateral", "COL");

    VaultController controllerImpl = new VaultController();
    vaultController = VaultController(
      address(
        new ERC1967Proxy(
          address(controllerImpl),
          abi.encodeWithSelector(
            controllerImpl.initialize.selector,
            acm,
            address(oracle),
            address(positionNFT),
            5e17, // closeFactorMantissa
            11e17, // liquidationIncentiveMantissa
            protocolTreasury,
            0 // protocolLiquidationShare
          )
        )
      )
    );
  }

  function _defaultVaultConfig()
    internal
    view
    returns (VaultConfig memory cfg)
  {
    cfg.supplyAsset = address(supplyToken);
    cfg.collateralAsset = address(collateralToken);
    cfg.minBorrowCap = 1_000 ether;
    cfg.maxBorrowCap = 2_000 ether;
    cfg.fundraisingDuration = 7 days;
    cfg.lockDuration = 30 days;
    cfg.settlementWindow = 5 days;
    cfg.fixedAPY = 1e17;
    cfg.reserveFactor = 1e17;
    cfg.autoLiquidateOnDueDate = true;
  }

  function _createVault() internal returns (address vault) {
    FixedRateLoanVault impl = new FixedRateLoanVault();
    vaultController.setLoanvaultImplementation(address(impl));
    VaultConfig memory cfg = _defaultVaultConfig();
    vault = vaultController.createVault(
      cfg,
      5e17, // collateralFactor
      7e17, // liquidationThreshold
      "Fixed Rate Vault",
      "FRV",
      institution,
      1_000 ether,
      liquidationAdapter
    );
  }

  function _setupVaultToLockWithBorrow(
    uint256 borrowAmount
  ) internal returns (address vault) {
    vault = _createVault();

    oracle.setPrice(address(supplyToken), 1e18);
    oracle.setPrice(address(collateralToken), 1e18);

    collateralToken.mint(institution, 1_000 ether);
    vm.startPrank(institution);
    collateralToken.approve(vault, type(uint256).max);
    IFixedRateLoanVault(vault).depositCollateral(1_000 ether);
    vm.stopPrank();

    vaultController.openVault(vault);

    supplyToken.mint(address(0xB0B), 2_000 ether);
    vm.startPrank(address(0xB0B));
    supplyToken.approve(vault, type(uint256).max);
    FixedRateLoanVault(vault).deposit(2_000 ether, address(0xB0B));
    vm.stopPrank();

    vm.prank(institution);
    FixedRateLoanVault(vault).borrow(borrowAmount);
  }

  function testSetLoanvaultImplementation() public {
    FixedRateLoanVault impl = new FixedRateLoanVault();
    vaultController.setLoanvaultImplementation(address(impl));
    assertEq(vaultController.loanVaultImplementation(), address(impl));
  }

  function testCreateVaultRevertsWhenImplNotSet() public {
    VaultConfig memory cfg = _defaultVaultConfig();

    vm.expectRevert(bytes("VC: impl not set"));
    vaultController.createVault(
      cfg,
      5e17,
      7e17,
      "Fixed Rate Vault",
      "FRV",
      institution,
      1_000 ether,
      liquidationAdapter
    );
  }

  function testCreateVaultRevertsWithInvalidConfig() public {
    FixedRateLoanVault impl = new FixedRateLoanVault();
    vaultController.setLoanvaultImplementation(address(impl));

    VaultConfig memory cfg = _defaultVaultConfig();
    cfg.maxBorrowCap = cfg.minBorrowCap; // invalid

    vm.expectRevert(
      bytes("VC: max borrow cap must be greater than min borrow cap")
    );
    vaultController.createVault(
      cfg,
      5e17,
      7e17,
      "Fixed Rate Vault",
      "FRV",
      institution,
      1_000 ether,
      liquidationAdapter
    );
  }

  function testCreateVaultWorksAndRegistersVault() public {
    address vault = _createVault();

    assertTrue(vaultController.isRegistered(vault));
  }

  function testPredictVaultAddressMatchesCreatedVault() public {
    FixedRateLoanVault impl = new FixedRateLoanVault();
    vaultController.setLoanvaultImplementation(address(impl));

    // First createVault mints tokenId=1 in MockPositionNFT.
    address predicted = vaultController.predictVaultAddress(1);
    VaultConfig memory cfg = _defaultVaultConfig();
    address created = vaultController.createVault(
      cfg,
      5e17,
      7e17,
      "Fixed Rate Vault",
      "FRV",
      institution,
      1_000 ether,
      liquidationAdapter
    );
    assertEq(predicted, created);
  }

  function testOpenVaultThroughControllerCallsVaultOpenVault() public {
    address vault = _createVault();

    // Deposit required initial collateral as institution to move to CollateralDeposited.
    collateralToken.mint(institution, 1_000 ether);
    vm.startPrank(institution);
    collateralToken.approve(vault, type(uint256).max);
    IFixedRateLoanVault(vault).depositCollateral(1_000 ether);
    vm.stopPrank();
    assertEq(
      uint8(FixedRateLoanVault(vault).vaultState()),
      uint8(VaultState.CollateralDeposited)
    );

    vaultController.openVault(vault);
    assertEq(
      uint8(FixedRateLoanVault(vault).vaultState()),
      uint8(VaultState.Open)
    );
  }

  function testOpenVaultRevertsForUnregisteredVault() public {
    vm.expectRevert(bytes("VC: unregistered vault"));
    vaultController.openVault(address(0x1234));
  }

  function testPauseUnpauseAndSetActionPausedRevertForUnregisteredVault()
    public
  {
    vm.expectRevert(bytes("VC: unregistered vault"));
    vaultController.pauseVault(address(0x1234));

    vm.expectRevert(bytes("VC: unregistered vault"));
    vaultController.unpauseVault(address(0x1234));

    vm.expectRevert(bytes("VC: unregistered vault"));
    vaultController.setVaultActionPaused(address(0x1234), 0, true);
  }

  function testRiskSetterFunctionsRevertForUnregisteredVault() public {
    vm.expectRevert(bytes("VC: unregistered vault"));
    vaultController.setCollateralFactor(address(0x1234), 5e17);

    vm.expectRevert(bytes("VC: unregistered vault"));
    vaultController.setLiquidationThreshold(address(0x1234), 7e17);
  }

  function testRiskSetterFunctionsRevertOnInvalidBounds() public {
    address vault = _createVault();

    vm.expectRevert(bytes("VC: collateral factor must be between 0 and 1"));
    vaultController.setCollateralFactor(vault, 0);

    vm.expectRevert(bytes("VC: liquidation threshold must be between 0 and 1"));
    vaultController.setLiquidationThreshold(vault, 0);

    vm.expectRevert(bytes("VC: liquidation incentive must be greater than 0"));
    vaultController.setLiquidationIncentive(0);

    vm.expectRevert(bytes("VC: close factor must be between 0 and 1"));
    vaultController.setCloseFactor(0);
  }

  function testSetRiskFunctionsWorkForRegisteredVault() public {
    address vault = _createVault();

    vaultController.setCollateralFactor(vault, 6e17);
    vaultController.setLiquidationThreshold(vault, 8e17);
    vaultController.setLiquidationIncentive(12e17);
    vaultController.setCloseFactor(6e17);

    (
      ,
      ,
      uint256 collateralFactor,
      uint256 liquidationThreshold
    ) = vaultController.vaults(vault);
    uint256 liquidationIncentive = vaultController
      .liquidationIncentiveMantissa();
    uint256 closeFactor = vaultController.closeFactorMantissa();
    assertEq(collateralFactor, 6e17);
    assertEq(liquidationThreshold, 8e17);
    assertEq(liquidationIncentive, 12e17);
    assertEq(closeFactor, 6e17);
  }

  function testPauseAndUnpauseVaultAffectsAllAllowedHooks() public {
    address vault = _createVault();

    // Pause all actions.
    vaultController.pauseVault(vault);

    vm.expectRevert(bytes("VC: action paused"));
    vaultController.borrowAllowed(vault, 1);
    vm.expectRevert(bytes("VC: action paused"));
    vaultController.withdrawAllowed(vault, 1);
    vm.expectRevert(bytes("VC: action paused"));
    vaultController.liquidateAllowed(vault, 1);

    // Unpause and simple hooks should pass again.
    vaultController.unpauseVault(vault);
    vaultController.borrowAllowed(vault, 1);
    vaultController.withdrawAllowed(vault, 1);
  }

  function testSetVaultActionPausedTargetsSingleAction() public {
    address vault = _createVault();

    // Pause only BORROW (enum index 1).
    vaultController.setVaultActionPaused(vault, 1, true);
    vm.expectRevert(bytes("VC: action paused"));
    vaultController.borrowAllowed(vault, 1);

    // Other actions stay unpaused.
    vaultController.withdrawAllowed(vault, 1);

    // Unpause same action.
    vaultController.setVaultActionPaused(vault, 1, false);
    vaultController.borrowAllowed(vault, 1);
  }

  function testBorrowAllowedRevertsOnShortfallAndPassesWhenHealthy() public {
    address vault = _createVault();

    collateralToken.mint(institution, 1_000 ether);
    vm.startPrank(institution);
    collateralToken.approve(vault, type(uint256).max);
    IFixedRateLoanVault(vault).depositCollateral(1_000 ether);
    vm.stopPrank();

    oracle.setPrice(address(supplyToken), 1e18);
    oracle.setPrice(address(collateralToken), 1e18);

    // adjusted collateral = 500; debt=0; borrow=600 => shortfall
    vm.expectRevert(bytes("VC: borrow shortfall"));
    vaultController.borrowAllowed(vault, 600 ether);

    // borrow=300 => debt+borrow=300 <= 500 => allowed
    vaultController.borrowAllowed(vault, 300 ether);
  }

  function testWithdrawAllowedRevertsOnShortfallAndPassesWhenHealthy() public {
    address vault = _setupVaultToLockWithBorrow(200 ether);

    // adjusted collateral = 500; withdraw=400 => effective=100 < debt=200 => shortfall
    vm.expectRevert(bytes("VC: withdraw shortfall"));
    vaultController.withdrawAllowed(vault, 400 ether);

    // withdraw=100 => effective=400 >= debt=200 => allowed
    vaultController.withdrawAllowed(vault, 100 ether);
  }

  function testLiquidateAllowedRevertsWithoutShortfallAndReturnsSeizeAmount()
    public
  {
    // No shortfall: outstanding ~416 (400 borrow + ~16 interest), threshold=700
    address vaultNoShortfall = _setupVaultToLockWithBorrow(400 ether);
    vm.expectRevert(bytes("VC: no shortfall"));
    vaultController.liquidateAllowed(vaultNoShortfall, 100 ether);

    // Shortfall by price move: collateral price drops by 50%.
    // threshold = 1000 * 0.5 * 0.7 = 350 < outstanding ~416 => shortfall.
    // repay=100, supplyPrice=1, collateralPrice=0.5, LI=1.1 => seize=220.
    address vaultShortfall = _setupVaultToLockWithBorrow(400 ether);
    oracle.setPrice(address(collateralToken), 5e17);
    uint256 seize = vaultController.liquidateAllowed(vaultShortfall, 100 ether);
    assertEq(seize, 220 ether);
  }
}
