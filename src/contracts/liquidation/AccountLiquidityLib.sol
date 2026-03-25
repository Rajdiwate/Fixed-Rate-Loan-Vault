// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/// @notice Stateless math library for account liquidity and liquidation calculations.
library AccountLiquidityLib {
  uint256 internal constant MANTISSA = 1e18;

  /// @notice Compute liquidity / shortfall after applying hypothetical borrow/withdraw.
  function getHypotheticalLiquidity(
    uint256 collateralUSD,
    uint256 debtUSD,
    uint256 cf,
    uint256 hypotheticalBorrowUSD,
    uint256 hypotheticalWithdrawUSD
  ) internal pure returns (uint256 liquidity, uint256 shortfall) {
    // adjustedCollateral = collateralUSD * cf
    uint256 adjustedCollateral = (collateralUSD * cf) / MANTISSA;

    // effectiveCollateral = adjustedCollateral - hypotheticalWithdrawUSD (floored at 0)
    uint256 effectiveCollateral;
    if (adjustedCollateral > hypotheticalWithdrawUSD) {
      effectiveCollateral = adjustedCollateral - hypotheticalWithdrawUSD;
    } else {
      effectiveCollateral = 0;
    }

    // totalDebt includes existing debt plus hypotheticalBorrowUSD
    uint256 totalDebt = debtUSD + hypotheticalBorrowUSD;

    if (effectiveCollateral >= totalDebt) {
      liquidity = effectiveCollateral - totalDebt;
      shortfall = 0;
    } else {
      liquidity = 0;
      shortfall = totalDebt - effectiveCollateral;
    }
  }

  /// @notice Compute shortfall with respect to the liquidation threshold.
  function getLiquidationShortfall(
    uint256 collateralUSD,
    uint256 debtUSD,
    uint256 lt
  ) internal pure returns (uint256 shortfall) {
    // thresholdCollateral = collateralUSD * lt
    uint256 thresholdCollateral = (collateralUSD * lt) / MANTISSA;

    if (debtUSD > thresholdCollateral) {
      shortfall = debtUSD - thresholdCollateral;
    } else {
      shortfall = 0;
    }
  }

  /// @notice Compute seize amount of collateral given a repayAmount and prices.
  function calculateSeizeAmount(
    uint256 repayAmount,
    uint256 supplyPriceUSD,
    uint256 collateralPriceUSD,
    uint256 liquidationIncentiveMantissa,
    uint8 supplyDecimals,
    uint8 collateralDecimals
  ) internal pure returns (uint256) {
    require(supplyPriceUSD > 0, "AccountLiquidityLib: supply price is 0");
    require(
      collateralPriceUSD > 0,
      "AccountLiquidityLib: collateral price is 0"
    );
    require(
      liquidationIncentiveMantissa > 0,
      "AccountLiquidityLib: liquidation incentive is 0"
    );
    require(supplyDecimals > 0, "AccountLiquidityLib: supply decimals is 0");
    require(
      collateralDecimals > 0,
      "AccountLiquidityLib: collateral decimals is 0"
    );

    // repayUSD = repayAmount * supplyPriceUSD / 10**supplyDecimals
    uint256 repayUSD = (repayAmount * supplyPriceUSD) / (10 ** supplyDecimals);

    // seizeUSD = repayUSD * liquidationIncentive / MANTISSA
    uint256 seizeUSD = (repayUSD * liquidationIncentiveMantissa) / MANTISSA;

    // seizeAmount = seizeUSD * 10**collateralDecimals / collateralPriceUSD
    uint256 seizeAmount = (seizeUSD * (10 ** collateralDecimals)) /
      collateralPriceUSD;

    return seizeAmount;
  }
}
