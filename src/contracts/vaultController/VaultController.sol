// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IVaultController} from "./IVaultController.sol";
import {VaultControllerStorage} from "./VaultControllerStorage.sol";
import {AccessControlledV8} from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {VaultStructs} from "../fixedRateLoanVault/VaultStructs.sol";
import {IFixedRateLoanVault} from "../fixedRateLoanVault/IFixedRateLoanVault.sol";
import {AccountLiquidityLib} from "../liquidation/AccountLiquidityLib.sol";
import {OracleInterface} from "@venusprotocol/oracle/contracts/interfaces/OracleInterface.sol";
import {IPositionNFT} from "../positionalNft/IPositionNFT.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IFixedRateLoanVaultState {
  function supplyAsset() external view returns (address);

  function collateralAsset() external view returns (address);

  function vaultState() external view returns (VaultStructs.VaultState);

  function totalBorrowed() external view returns (uint256);

  function totalRepaid() external view returns (uint256);

  function totalRaised() external view returns (uint256);

  function totalCollateral() external view returns (uint256);
}

/// @notice Skeleton implementation contract for the VaultController.
/// @dev All functions are left unimplemented and should be filled in following
///      the Institutional Fixed Rate specification.
contract VaultController is
  AccessControlledV8,
  ReentrancyGuardUpgradeable,
  IVaultController,
  VaultControllerStorage
{
  constructor() {
    _disableInitializers();
  }

  function initialize(
    address acm,
    address oracle,
    address positionNFT_,
    uint256 closeFactorMantissa_,
    uint256 liquidationIncentiveMantissa_,
    address protocolTreasury_,
    uint256 protocolLiquidationShare_
  ) public initializer {
    require(
      closeFactorMantissa_ > 0 && closeFactorMantissa_ <= 1e18,
      "VC: invalid close factor"
    );
    require(
      liquidationIncentiveMantissa_ > 0,
      "VC: invalid liquidation incentive"
    );
    require(
      protocolLiquidationShare_ <= 1e18,
      "VC: invalid protocol liquidation share"
    );
    require(positionNFT_ != address(0), "VC: invalid position NFT");
    require(protocolTreasury_ != address(0), "VC: invalid protocol treasury");
    __AccessControlled_init(acm);
    __ReentrancyGuard_init();
    resilientOracle = OracleInterface(oracle);
    positionNFT = IPositionNFT(positionNFT_);
    closeFactorMantissa = closeFactorMantissa_;
    liquidationIncentiveMantissa = liquidationIncentiveMantissa_;
    protocolTreasury = protocolTreasury_;
    protocolLiquidationShare = protocolLiquidationShare_;
  }

  function setLoanvaultImplementation(address implementation) external {
    _checkAccessAllowed("setLoanvaultImplementation(address)");
    loanVaultImplementation = implementation;
  }

  // --- IVaultController: Vault Deployment ---

  function createVault(
    VaultConfig memory vaultConfig,
    uint256 collateralFactorMantissa,
    uint256 liquidationThresholdMantissa,
    string memory name_,
    string memory symbol_,
    address institution,
    uint256 requiredInitialCollateral,
    address liquidationAdapter
  ) external nonReentrant returns (address) {
    _checkAccessAllowed(
      "createVault(VaultConfig,uint256,uint256,string,string,address,uint256,address)"
    );
    {
      _validateVaultConfig(vaultConfig);
      require(
        collateralFactorMantissa > 0 && collateralFactorMantissa <= 1e18,
        "VC: invalid CF"
      );
      require(
        liquidationThresholdMantissa > 0 &&
          liquidationThresholdMantissa <= 1e18,
        "VC: invalid LT"
      );
      require(
        liquidationAdapter != address(0),
        "VC: liquidation adapter not set"
      );
      require(loanVaultImplementation != address(0), "VC: impl not set");
    }

    // Mint the position NFT first so we can use the tokenId as the deterministic salt.
    uint256 positionTokenId = positionNFT.mint(institution);

    // EIP-1167 minimal proxy clone of the LoanVault implementation using OZ Clones (CREATE2),
    // using only the NFT tokenId as the salt for determinism.
    address vault = Clones.cloneDeterministic(
      loanVaultImplementation,
      keccak256(abi.encode(positionTokenId))
    );
    require(vault != address(0), "VC: clone failed");

    IFixedRateLoanVault(vault).initialize(
      vaultConfig,
      IVaultController(address(this)),
      positionNFT,
      positionTokenId,
      requiredInitialCollateral,
      name_,
      symbol_,
      liquidationAdapter
    );

    // Register the newly created vault.
    allVaults.push(IFixedRateLoanVault(vault));
    vaults[vault] = Vault(
      vault,
      true,
      collateralFactorMantissa,
      liquidationThresholdMantissa
    );

    emit VaultCreated(vault, institution, positionTokenId);

    return vault;
  }

  function _validateVaultConfig(VaultConfig memory cfg) internal pure {
    require(cfg.supplyAsset != address(0), "VC: zero supply asset");
    require(cfg.collateralAsset != address(0), "VC: zero collateral");
    require(cfg.minBorrowCap > 0, "VC: min borrow cap must be greater than 0");
    require(
      cfg.maxBorrowCap > cfg.minBorrowCap,
      "VC: max borrow cap must be greater than min borrow cap"
    );
    require(
      cfg.fundraisingDuration > 0,
      "VC: fundraising duration must be greater than 0"
    );
    require(cfg.lockDuration > 0, "VC: invalid lock duration");
    require(cfg.settlementWindow > 0, "VC: invalid settlement window");
    require(cfg.fixedAPY > 0, "VC: fixed APY must be greater than 0");
    require(
      cfg.reserveFactor > 0 && cfg.reserveFactor <= 1e18,
      "VC: reserve factor must be between 0 and 1"
    );
  }

  function predictVaultAddress(
    uint256 positionTokenId
  ) external view override returns (address) {
    require(loanVaultImplementation != address(0), "VC: impl not set");

    bytes32 salt = keccak256(abi.encode(positionTokenId));

    // Predict the address that will be used by cloneDeterministic with the same salt.
    return
      Clones.predictDeterministicAddress(
        loanVaultImplementation,
        salt,
        address(this)
      );
  }

  // --- IVaultController: Operator-Proxied Vault Lifecycle ---

  function openVault(address vault) external {
    _checkAccessAllowed("openVault(address)");
    require(vaults[vault].isVaultRegistered, "VC: unregistered vault");

    // check if sufficient collateral is deposited and if the vault is in CollateralDeposited state in the VAULT itself
    IFixedRateLoanVault(vault).openVault();
  }

  function pauseVault(address vault) external {
    _checkAccessAllowed("pauseVault(address)");
    require(vaults[vault].isVaultRegistered, "VC: unregistered vault");

    // Pause all core actions for the given vault.
    for (uint8 i = 0; i <= uint8(VaultAction.LIQUIDATE); i++) {
      if (!vaultActionPaused[vault][i]) {
        vaultActionPaused[vault][i] = true;
        emit VaultActionPaused(vault, i, true);
      }
    }
  }

  function unpauseVault(address vault) external {
    _checkAccessAllowed("unpauseVault(address)");
    require(vaults[vault].isVaultRegistered, "VC: unregistered vault");

    // Unpause all core actions for the given vault.
    for (uint8 i = 0; i <= uint8(VaultAction.LIQUIDATE); i++) {
      if (vaultActionPaused[vault][i]) {
        vaultActionPaused[vault][i] = false;
        emit VaultActionPaused(vault, i, false);
      }
    }
  }

  function setVaultActionPaused(
    address vault,
    uint8 action,
    bool paused
  ) external {
    _checkAccessAllowed("setVaultActionPaused(address,uint8,bool)");
    require(vaults[vault].isVaultRegistered, "VC: unregistered vault");
    require(action <= uint8(VaultAction.LIQUIDATE), "VC: invalid action");
    vaultActionPaused[vault][action] = paused;
    emit VaultActionPaused(vault, action, paused);
  }

  // --- IVaultController: Risk Parameter Setters ---

  function setCollateralFactor(address vault, uint256 newCF) external {
    _checkAccessAllowed("setCollateralFactor(address,uint256)");
    require(vaults[vault].isVaultRegistered, "VC: unregistered vault");
    require(
      newCF > 0 && newCF <= 1e18,
      "VC: collateral factor must be between 0 and 1"
    );
    vaults[vault].collateralFactorMantissa = newCF;
    emit CollateralFactorUpdated(vault, newCF);
  }

  function setLiquidationThreshold(address vault, uint256 newLT) external {
    _checkAccessAllowed("setLiquidationThreshold(address,uint256)");
    require(vaults[vault].isVaultRegistered, "VC: unregistered vault");
    require(
      newLT > 0 && newLT <= 1e18,
      "VC: liquidation threshold must be between 0 and 1"
    );
    vaults[vault].liquidationThresholdMantissa = newLT;
    emit LiquidationThresholdUpdated(vault, newLT);
  }

  function setLiquidationIncentive(uint256 newLI) external {
    _checkAccessAllowed("setLiquidationIncentive(uint256)");
    require(newLI > 0, "VC: liquidation incentive must be greater than 0");
    liquidationIncentiveMantissa = newLI;
    emit LiquidationIncentiveUpdated(newLI);
  }

  function setCloseFactor(uint256 newCloseFactor) external {
    _checkAccessAllowed("setCloseFactor(uint256)");
    require(
      newCloseFactor > 0 && newCloseFactor <= 1e18,
      "VC: close factor must be between 0 and 1"
    );
    closeFactorMantissa = newCloseFactor;
    emit CloseFactorUpdated(newCloseFactor);
  }

  function setProtocolLiquidationShare(uint256 share) external {
    _checkAccessAllowed("setProtocolLiquidationShare(uint256)");
    require(
      share <= 1e18,
      "VC: protocol liquidation share must be less than or equal to 1"
    );
    protocolLiquidationShare = share;
    emit ProtocolLiquidationShareUpdated(share);
  }

  // --- IVaultController: Vault Registry ---

  function isRegistered(address vault) external view returns (bool) {
    return vaults[vault].isVaultRegistered;
  }

  // --- IVaultController: Risk Hooks (called by vault) ---

  function borrowAllowed(address vault, uint256 borrowAmount) external view {
    _checkRegisteredVault(vault);
    _checkActionNotPaused(vault, VaultAction.BORROW);

    IFixedRateLoanVaultState v = IFixedRateLoanVaultState(vault);
    address supplyAsset = v.supplyAsset();
    address collateralAsset = v.collateralAsset();
    uint256 collateralFactor = vaults[vault].collateralFactorMantissa;
    uint256 totalCollateral = v.totalCollateral();

    uint256 collateralPrice = resilientOracle.getPrice(collateralAsset);

    uint256 borrowPrice = resilientOracle.getPrice(supplyAsset);

    uint256 collateralUSD = (totalCollateral * collateralPrice) / 1e18;

    uint256 debtAmount = IFixedRateLoanVault(vault).outstandingRepayment();

    uint256 debtUSD = (debtAmount * borrowPrice) / 1e18;

    uint256 borrowUSD = (borrowAmount * borrowPrice) / 1e18;

    (, uint256 shortfall) = AccountLiquidityLib.getHypotheticalLiquidity(
      collateralUSD,
      debtUSD,
      collateralFactor,
      borrowUSD,
      0
    );

    require(shortfall == 0, "VC: borrow shortfall");
  }

  function withdrawAllowed(
    address vault,
    uint256 withdrawAmount
  ) external view {
    _checkRegisteredVault(vault);
    _checkActionNotPaused(vault, VaultAction.WITHDRAW);

    IFixedRateLoanVaultState v = IFixedRateLoanVaultState(vault);
    address supplyAsset = v.supplyAsset();
    address collateralAsset = v.collateralAsset();
    uint256 collateralFactor = vaults[vault].collateralFactorMantissa;
    uint256 totalCollateral = v.totalCollateral();
    uint256 debtAmount = IFixedRateLoanVault(vault).outstandingRepayment();

    // If there is no outstanding debt, withdrawal cannot create a shortfall.
    if (debtAmount == 0) {
      return;
    }

    uint256 collateralPrice = resilientOracle.getPrice(collateralAsset);

    uint256 borrowPrice = resilientOracle.getPrice(supplyAsset);

    uint256 collateralUSD = (totalCollateral * collateralPrice) / 1e18;

    uint256 debtUSD = (debtAmount * borrowPrice) / 1e18;

    uint256 withdrawUSD = (withdrawAmount * collateralPrice) / 1e18;

    (, uint256 shortfall) = AccountLiquidityLib.getHypotheticalLiquidity(
      collateralUSD,
      debtUSD,
      collateralFactor,
      0,
      withdrawUSD
    );

    require(shortfall == 0, "VC: withdraw shortfall");
  }

  function liquidateAllowed(
    address vault,
    uint256 repayAmount
  ) external view override returns (uint256) {
    require(repayAmount > 0, "FV: repay amount is zero");
    _checkRegisteredVault(vault);
    _checkActionNotPaused(vault, VaultAction.LIQUIDATE);

    IFixedRateLoanVaultState v = IFixedRateLoanVaultState(vault);
    address supplyAsset = v.supplyAsset();
    address collateralAsset = v.collateralAsset();
    uint256 debtAmount = IFixedRateLoanVault(vault).outstandingRepayment();
    uint256 liquidationThreshold = vaults[vault].liquidationThresholdMantissa;
    uint256 totalCollateral = v.totalCollateral();

    require(
      repayAmount <= (debtAmount * closeFactorMantissa) / 1e18,
      "VC: repay amount exceeds close factor"
    );

    uint256 collateralPrice = resilientOracle.getPrice(collateralAsset);

    uint256 borrowPrice = resilientOracle.getPrice(supplyAsset);

    uint256 collateralUSD = (totalCollateral * collateralPrice) / 1e18;

    uint256 debtUSD = (debtAmount * borrowPrice) / 1e18;

    uint256 shortfall = AccountLiquidityLib.getLiquidationShortfall(
      collateralUSD,
      debtUSD,
      liquidationThreshold
    );

    require(shortfall > 0, "VC: no shortfall");

    return
      AccountLiquidityLib.calculateSeizeAmount(
        repayAmount,
        borrowPrice,
        collateralPrice,
        liquidationIncentiveMantissa,
        IERC20Metadata(supplyAsset).decimals(),
        IERC20Metadata(collateralAsset).decimals()
      );
  }

  function _checkRegisteredVault(address vault) internal view {
    require(vaults[vault].isVaultRegistered, "VC: unregistered vault");
  }

  function _checkActionNotPaused(
    address vault,
    VaultAction action
  ) internal view {
    require(!vaultActionPaused[vault][uint8(action)], "VC: action paused");
  }
}
