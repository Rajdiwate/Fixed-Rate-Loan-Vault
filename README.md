# Fixed-Rate Loan Vault

An institutional fixed-rate lending protocol built on ERC-4626 (upgradeable) with a collateral-backed, state-machine-driven vault lifecycle. Liquidity providers deposit a supply asset in exchange for vault shares, while institutions borrow against posted collateral at a predetermined fixed APY.

Built with [Foundry](https://book.getfoundry.sh/) and Solidity 0.8.30.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                        VaultController                           │
│  (AccessControlledV8, ReentrancyGuardUpgradeable)                │
│                                                                  │
│  • Creates vault clones (EIP-1167 minimal proxies)               │
│  • Manages risk parameters (collateral factor, LT, close factor) │
│  • Enforces borrow / withdraw / liquidation constraints          │
│  • Reads prices from ResilientOracle                             │
└──────┬───────────────┬─────────────────────────┬─────────────────┘
       │               │                         │
       │ createVault   │ risk hooks              │ oracle queries
       ▼               ▼                         ▼
┌─────────────┐ ┌─────────────────────┐   ┌──────────────────┐
│ PositionNFT │ │ FixedRateLoanVault  │   │  ResilientOracle  │
│ (ERC-721)   │ │ (ERC-4626 clone)    │   │  (Venus)          │
│             │ │                     │   └──────────────────┘
│ 1 NFT per   │ │ • LP deposits       │
│ vault ─      │ │ • Institution borrow│
│ institution  │ │ • Repay + settle    │
│ identity     │ │ • State machine     │
└─────────────┘ └──────────┬──────────┘
                           │ liquidate (adapter only)
                           ▼
                ┌─────────────────────┐
                │ LiquidationAdapter  │
                │                     │
                │ • Whitelist-gated   │
                │ • Routes repayment  │
                │ • Splits seized     │
                │   collateral        │
                └─────────────────────┘
```

### Contract Dependency Graph

| Contract | Depends On |
|---|---|
| `FixedRateLoanVault` | `LoanVaultBase`, `VaultStorage`, `IFixedRateLoanVault`, `VaultController` (risk hooks), `PositionNFT` (institution identity) |
| `LoanVaultBase` | OpenZeppelin `ERC4626Upgradeable`, `ReentrancyGuardUpgradeable`, `Initializable` |
| `VaultController` | Venus `AccessControlledV8`, `AccountLiquidityLib`, `OracleInterface`, `PositionNFT`, `Clones` (EIP-1167) |
| `LiquidationAdapter` | Venus `AccessControlledV8`, `VaultController` (reads vault registry + treasury), `FixedRateLoanVault` |
| `PositionNFT` | OpenZeppelin `ERC721`, `Ownable2Step` |

---

## Vault Lifecycle

Each vault progresses through a deterministic state machine (`VaultState` enum):

```
WaitingForCollateral
        │
        │  institution deposits required collateral
        ▼
 CollateralDeposited
        │
        │  controller calls openVault()
        ▼
       Open  ──────────────────────────┐
        │                              │
        │  fundraising ends            │  totalRaised < minBorrowCap
        │  (totalRaised >= minCap)     ▼
        │                           Failed
        │                         (LPs withdraw)
        │  OR maxBorrowCap reached
        ▼
       Lock
        │
        │  lockDuration elapses
        ▼
 PendingSettlement
        │
        ├── institution repays in full ──► Claimable ──► Closed
        │                                  (LPs withdraw)
        │  settlementWindow elapses
        ▼
    TermExpired
        │
        │  repaid via liquidation or institution
        ▼
     Claimable ──► Closed
```

### State Transitions at a Glance

| From | To | Trigger |
|---|---|---|
| `WaitingForCollateral` | `CollateralDeposited` | `depositCollateral()` fills required amount |
| `CollateralDeposited` | `Open` | Controller calls `openVault()` |
| `Open` | `Lock` | Fundraising ends with `totalRaised >= minBorrowCap`, or max cap reached |
| `Open` | `Failed` | Fundraising ends with `totalRaised < minBorrowCap` |
| `Lock` | `PendingSettlement` | `lockDuration` elapses |
| `PendingSettlement` | `Claimable` | Debt fully repaid (triggers `_settleVault`) |
| `PendingSettlement` | `TermExpired` | Settlement window elapses without full repayment |
| `TermExpired` | `Claimable` | Debt fully repaid |
| `Claimable` | `Closed` | `closeFull()` — zero debt, zero collateral |

---

## Contracts

### `FixedRateLoanVault`

**Path:** `src/contracts/fixedRateLoanVault/FixedRateLoanVault.sol`

The core vault contract deployed as an EIP-1167 clone by `VaultController`. Extends ERC-4626 for LP share accounting and implements the full loan lifecycle.

**Key functions:**

| Function | Access | Description |
|---|---|---|
| `initialize(...)` | Controller (once) | Sets config, collateral requirements, controller/NFT references |
| `depositCollateral(amount)` | Institution | Deposits collateral asset during `WaitingForCollateral` |
| `addCollateral(amount)` | Institution | Tops up collateral during `Lock` |
| `withdrawCollateral(amount)` | Institution | Withdraws excess or remaining collateral (risk-checked) |
| `borrow(amount)` | Institution | Borrows supply asset up to `totalRaised` (risk-checked) |
| `repay(amount)` | Institution | Repays supply asset, capped at `outstandingRepayment()` |
| `deposit(assets, receiver)` | LP (public) | ERC-4626 deposit — only during `Open` |
| `withdraw(assets, ...)` | LP (public) | ERC-4626 withdraw — only during `Claimable` or `Failed` |
| `liquidate(repayAmount)` | Liquidation adapter | Seizes collateral proportional to repayment |
| `closeFull()` | Institution | Transitions `Claimable` → `Closed` when fully settled |

**Modifiers:** `onlyInstitution` (NFT owner), `onlyController`, `onlyLiquidationAdapter`.

**Events:** `VaultStateUpdated`, `CollateralDeposited`, `CollateralWithdrawn`, `ShortfallDetected`, `LiquidationExecuted`.

### `LoanVaultBase`

**Path:** `src/contracts/loanVaultBase/LoanVaultBase.sol`

Abstract base inheriting `ERC4626Upgradeable`, `ReentrancyGuardUpgradeable`, and `Initializable`. Provides:

- Common storage: `supplyAsset`, `fixedAPY`, `maxBorrowCap`, `minBorrowCap`, `totalBorrowed`, `totalRepaid`, `totalRaised`
- Interest calculation: `principal × fixedAPY × duration / 365 days / 1e18`
- Overridden ERC-4626 hooks (`maxDeposit`, `maxWithdraw`, `totalAssets`) delegating to virtual functions
- `nonReentrant` guards on all deposit/mint/withdraw/redeem paths
- Auto-lock when `totalRaised == maxBorrowCap`

### `VaultController`

**Path:** `src/contracts/vaultController/VaultController.sol`

The protocol's central coordinator. Uses Venus `AccessControlledV8` for role-based access.

**Key functions:**

| Function | Description |
|---|---|
| `createVault(institution, config, riskParams)` | Mints position NFT, deploys deterministic clone, initializes and registers vault |
| `predictVaultAddress(positionTokenId)` | Computes the clone address from the salt |
| `openVault(vault)` | Triggers fundraising start |
| `borrowAllowed(vault, institution, amount)` | Checks collateral-to-debt ratio via oracle; returns max borrowable |
| `withdrawAllowed(vault, institution, amount)` | Checks that withdrawal keeps vault solvent |
| `liquidateAllowed(vault, repayAmount)` | Validates shortfall, applies close factor, calculates seize amount |
| `setCollateralFactor(...)` | Updates vault-level collateral factor |
| `setLiquidationThreshold(...)` | Updates vault-level liquidation threshold |
| `setCloseFactor(...)` | Updates protocol close factor |
| `setVaultActionPaused(vault, action, paused)` | Circuit breaker for borrow/withdraw/liquidate per vault |

### `LiquidationAdapter`

**Path:** `src/contracts/liquidation/LiquidationAdapter.sol`

Whitelist-gated entrypoint for third-party liquidators.

**Flow:**
1. Liquidator calls `liquidate(vault, repayAmount)`
2. Adapter transfers supply asset from liquidator into the vault
3. Vault seizes collateral and sends it to the adapter
4. Adapter splits collateral: liquidator receives their share, protocol treasury receives `protocolLiquidationShare`

### `AccountLiquidityLib`

**Path:** `src/contracts/liquidation/AccountLiquidityLib.sol`

Pure math library used by `VaultController` for:
- `getHypotheticalLiquidity` — computes (liquidity, shortfall) for a vault given oracle prices and risk parameters
- `getLiquidationShortfall` — checks if a vault is underwater using the liquidation threshold
- `calculateSeizeAmount` — determines collateral to seize for a given repay amount plus incentive

### `PositionNFT`

**Path:** `src/contracts/positionalNft/PositionNFT.sol`

ERC-721 token representing institutional vault ownership. One NFT per vault, minted by `VaultController` during `createVault`. Transfers are restricted to the contract owner (governance) to prevent unauthorized position handoffs.

### `VaultStructs`

**Path:** `src/contracts/fixedRateLoanVault/VaultStructs.sol`

Shared type definitions:

- **`VaultState`** enum — the 9 lifecycle states listed above
- **`VaultConfig`** struct — immutable vault parameters set at creation: `supplyAsset`, `collateralAsset`, `minBorrowCap`, `maxBorrowCap`, `fundraisingDuration`, `lockDuration`, `settlementWindow`, `fixedAPY`, `reserveFactor`, `autoLiquidateOnDueDate`

---

## Risk Model

The protocol enforces solvency constraints through oracle-priced collateral checks:

| Parameter | Purpose |
|---|---|
| **Collateral Factor** | Maximum ratio of debt-to-collateral value allowed for borrowing |
| **Liquidation Threshold** | Ratio at which a vault becomes liquidatable |
| **Close Factor** | Maximum fraction of debt repayable in a single liquidation call |
| **Liquidation Incentive** | Bonus collateral awarded to liquidators |
| **Protocol Liquidation Share** | Fraction of seized collateral directed to the protocol treasury |

All USD valuations are sourced from a Venus `ResilientOracle`.

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| `@openzeppelin/contracts` | ^5.6.1 | ERC-20/721, Clones (EIP-1167), ERC1967Proxy |
| `@openzeppelin/contracts-upgradeable` | 4.8.3 | Initializable, ERC4626Upgradeable, ReentrancyGuardUpgradeable |
| `@venusprotocol/governance-contracts` | ^2.13.0 | AccessControlledV8 (role-based access) |
| `@venusprotocol/oracle` | ^2.14.0 | OracleInterface / ResilientOracle |
| `forge-std` | (submodule) | Foundry test framework |

---

## Usage

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

### Local Node

```shell
anvil
```
