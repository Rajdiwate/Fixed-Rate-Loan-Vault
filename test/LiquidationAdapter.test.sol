// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {LiquidationAdapter} from "../src/contracts/liquidation/LiquidationAdapter.sol";
import {MockAccessControlManager} from "./mocks/MockAccessControlManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract FalseERC20 {
  bool public failTransfer;
  bool public failTransferFrom;

  function setFailTransfer(bool v) external {
    failTransfer = v;
  }

  function setFailTransferFrom(bool v) external {
    failTransferFrom = v;
  }

  function transfer(address, uint256) external view returns (bool) {
    if (failTransfer) {
      return false;
    }
    return true;
  }

  function transferFrom(
    address,
    address,
    uint256
  ) external view returns (bool) {
    if (failTransferFrom) {
      return false;
    }
    return true;
  }

  function approve(address, uint256) external pure returns (bool) {
    return true;
  }
}

contract FailSecondTransferERC20 {
  uint256 internal transferCalls;

  function transfer(address, uint256) external returns (bool) {
    transferCalls += 1;
    if (transferCalls == 2) {
      return false;
    }
    return true;
  }

  function transferFrom(
    address,
    address,
    uint256
  ) external pure returns (bool) {
    return true;
  }

  function approve(address, uint256) external pure returns (bool) {
    return true;
  }
}

/// @dev Minimal mock matching VaultControllerStorage getters used by LiquidationAdapter.
contract MockControllerForAdapter {
  struct Vault {
    address vault;
    bool isVaultRegistered;
    uint256 collateralFactorMantissa;
    uint256 liquidationThresholdMantissa;
  }

  mapping(address => Vault) public vaults;
  address public protocolTreasury;
  uint256 public protocolLiquidationShare;

  constructor(address treasury_, uint256 share_) {
    protocolTreasury = treasury_;
    protocolLiquidationShare = share_;
  }

  function registerVault(address vault) external {
    vaults[vault] = Vault(vault, true, 5e17, 7e17);
  }
}

contract MockLiquidationVault {
  address public supplyAsset;
  address public collateralAsset;
  uint256 public seizeAmountToReturn;

  constructor(address supplyAsset_, address collateralAsset_) {
    supplyAsset = supplyAsset_;
    collateralAsset = collateralAsset_;
  }

  function setSeizeAmountToReturn(uint256 amount) external {
    seizeAmountToReturn = amount;
  }

  function outstandingRepayment() external pure returns (uint256) {
    return type(uint256).max;
  }

  function liquidate(uint256) external returns (uint256) {
    if (seizeAmountToReturn > 0) {
      bool ok = MockERC20(collateralAsset).transfer(
        msg.sender,
        seizeAmountToReturn
      );
      require(ok, "mock vault: collateral transfer failed");
    }
    return seizeAmountToReturn;
  }
}

contract MockLiquidationVaultFalseCollateral {
  address public supplyAsset;
  address public collateralAsset;
  uint256 public seizeAmountToReturn;

  constructor(address supplyAsset_, address collateralAsset_) {
    supplyAsset = supplyAsset_;
    collateralAsset = collateralAsset_;
  }

  function setSeizeAmountToReturn(uint256 amount) external {
    seizeAmountToReturn = amount;
  }

  function outstandingRepayment() external pure returns (uint256) {
    return type(uint256).max;
  }

  function liquidate(uint256) external view returns (uint256) {
    return seizeAmountToReturn;
  }
}

contract LiquidationAdapterTest is Test {
  LiquidationAdapter internal adapter;
  MockAccessControlManager internal acm;
  MockControllerForAdapter internal mockController;
  MockERC20 internal supplyToken;
  MockERC20 internal collateralToken;

  address internal treasury = address(0xBEEF);
  address internal liquidator = address(0xA11CE);
  uint256 internal constant ONE = 1e18;

  function setUp() public {
    acm = new MockAccessControlManager();
    supplyToken = new MockERC20("Supply", "SUP");
    collateralToken = new MockERC20("Collateral", "COL");
    mockController = new MockControllerForAdapter(treasury, 2e17);

    LiquidationAdapter impl = new LiquidationAdapter();
    adapter = LiquidationAdapter(
      address(
        new ERC1967Proxy(
          address(impl),
          abi.encodeWithSelector(
            impl.initialize.selector,
            address(mockController),
            address(acm)
          )
        )
      )
    );
  }

  function testInitializeSetsConfig() public view {
    assertEq(adapter.controller(), address(mockController));
  }

  function testWhitelistSetAndRead() public {
    adapter.setLiquidatorWhitelist(liquidator, true);
    assertTrue(adapter.isWhitelistedLiquidator(liquidator));

    adapter.setLiquidatorWhitelist(liquidator, false);
    assertFalse(adapter.isWhitelistedLiquidator(liquidator));
  }

  function testLiquidateRevertsWhenNotWhitelisted() public {
    MockLiquidationVault vault = new MockLiquidationVault(
      address(supplyToken),
      address(collateralToken)
    );
    vm.expectRevert(bytes("not whitelisted"));
    adapter.liquidate(address(vault), 1 ether);
  }

  function testLiquidateRevertsOnSupplyTransferFailure() public {
    FalseERC20 falseSupply = new FalseERC20();
    falseSupply.setFailTransferFrom(true);
    MockLiquidationVaultFalseCollateral vault = new MockLiquidationVaultFalseCollateral(
        address(falseSupply),
        address(collateralToken)
      );
    vault.setSeizeAmountToReturn(1 ether);
    mockController.registerVault(address(vault));

    adapter.setLiquidatorWhitelist(liquidator, true);
    vm.prank(liquidator);
    vm.expectRevert(bytes("LiquidationAdapter: supply asset transfer failed"));
    adapter.liquidate(address(vault), 1 ether);
  }

  function testLiquidateRevertsOnCollateralTransferFailure() public {
    FalseERC20 falseCollateral = new FalseERC20();
    falseCollateral.setFailTransfer(true);

    MockLiquidationVaultFalseCollateral vault = new MockLiquidationVaultFalseCollateral(
        address(supplyToken),
        address(falseCollateral)
      );
    vault.setSeizeAmountToReturn(1 ether);
    mockController.registerVault(address(vault));

    supplyToken.mint(liquidator, 10 ether);
    adapter.setLiquidatorWhitelist(liquidator, true);

    vm.startPrank(liquidator);
    supplyToken.approve(address(adapter), type(uint256).max);
    vm.expectRevert(bytes("LiquidationAdapter: collateral transfer failed"));
    adapter.liquidate(address(vault), 1 ether);
    vm.stopPrank();
  }

  function testLiquidateRevertsWhenTreasuryCollateralTransferFails() public {
    FailSecondTransferERC20 failSecond = new FailSecondTransferERC20();
    MockLiquidationVaultFalseCollateral vault = new MockLiquidationVaultFalseCollateral(
        address(supplyToken),
        address(failSecond)
      );
    vault.setSeizeAmountToReturn(10 ether);
    mockController.registerVault(address(vault));

    supplyToken.mint(liquidator, 10 ether);
    adapter.setLiquidatorWhitelist(liquidator, true);

    vm.startPrank(liquidator);
    supplyToken.approve(address(adapter), type(uint256).max);
    vm.expectRevert(bytes("LiquidationAdapter: collateral transfer failed"));
    adapter.liquidate(address(vault), 1 ether);
    vm.stopPrank();
  }

  function testLiquidateSuccessSplitsCollateral() public {
    MockLiquidationVault vault = new MockLiquidationVault(
      address(supplyToken),
      address(collateralToken)
    );
    vault.setSeizeAmountToReturn(10 ether);
    mockController.registerVault(address(vault));

    collateralToken.mint(address(vault), 10 ether);
    supplyToken.mint(liquidator, 5 ether);

    adapter.setLiquidatorWhitelist(liquidator, true);
    vm.startPrank(liquidator);
    supplyToken.approve(address(adapter), type(uint256).max);
    adapter.liquidate(address(vault), 5 ether);
    vm.stopPrank();

    // 20% treasury, 80% liquidator
    assertEq(collateralToken.balanceOf(treasury), 2 ether);
    assertEq(collateralToken.balanceOf(liquidator), 8 ether);
  }
}
