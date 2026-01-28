// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Simple utilization-based interest rate model (Aave-style but simplified)
/// @notice This is NOT production ready. It is a teaching/demo implementation.
contract InterestRateModel {
    /// @notice All rates are expressed in ray (1e27), per second.
    /// For example, 5% APR ~= 0.05 / 365 days ≈ 1.585e-9 per second.
    /// In ray: 1.585e-9 * 1e27 = 1.585e18.

    uint256 public immutable RAY = 1e27;

    /// @notice Base variable borrow rate when utilization is 0.
    uint256 public immutable baseVariableBorrowRate;

    /// @notice Slope of the borrow rate when utilization is below the kink.
    uint256 public immutable slope1;

    /// @notice Slope of the borrow rate when utilization is above the kink.
    uint256 public immutable slope2;

    /// @notice Utilization point (in ray) where the slope changes.
    uint256 public immutable optimalUtilization;

    constructor(
        uint256 _baseVariableBorrowRate,
        uint256 _slope1,
        uint256 _slope2,
        uint256 _optimalUtilization
    ) {
        require(_optimalUtilization <= RAY, "INVALID_OPTIMAL_UTILIZATION");
        baseVariableBorrowRate = _baseVariableBorrowRate;
        slope1 = _slope1;
        slope2 = _slope2;
        optimalUtilization = _optimalUtilization;
    }

    /// @notice Compute utilization of a reserve.
    /// @param totalLiquidity Total liquidity (deposits) in the reserve
    /// @param totalBorrows Total borrows in the reserve
    /// @return utilization Utilization in ray (0..1e27)
    function getUtilization(
        uint256 totalLiquidity,
        uint256 totalBorrows
    ) public pure returns (uint256 utilization) {
        if (totalBorrows == 0 || totalLiquidity == 0) {
            return 0;
        }
        // utilization = totalBorrows / totalLiquidity (in ray)
        utilization = (totalBorrows * 1e27) / totalLiquidity;
    }

    /// @notice Get current variable borrow rate for a reserve.
    /// @param totalLiquidity Total liquidity
    /// @param totalBorrows Total borrows
    function getVariableBorrowRate(
        uint256 totalLiquidity,
        uint256 totalBorrows
    ) external view returns (uint256) {
        uint256 utilization = getUtilization(totalLiquidity, totalBorrows);

        if (utilization == 0) {
            return baseVariableBorrowRate;
        }

        if (utilization <= optimalUtilization) {
            // Linear increase up to the kink
            // rate = base + slope1 * utilization / optimalUtilization
            uint256 factor = (utilization * 1e27) / optimalUtilization;
            return baseVariableBorrowRate + (slope1 * factor) / 1e27;
        } else {
            // Beyond kink
            // rate = base + slope1 + slope2 * (utilization - optimalUtilization) / (RAY - optimalUtilization)
            uint256 excessUtil = utilization - optimalUtilization;
            uint256 denom = (RAY - optimalUtilization);
            uint256 factor = denom == 0 ? 0 : (excessUtil * 1e27) / denom;
            return baseVariableBorrowRate + slope1 + (slope2 * factor) / 1e27;
        }
    }
}
