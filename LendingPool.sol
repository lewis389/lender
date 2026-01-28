// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IERC20.sol";
import "./InterestRateModel.sol";

/// @title Minimal Aave-style overcollateralized lending pool (simplified)
/// @notice This is a teaching/demo implementation only. Do NOT use in production.
contract LendingPool {
    struct ReserveConfig {
        bool isActive;
        bool isFrozen;
        uint256 collateralFactor; // e.g. 0.75e18 = 75%, in wad (1e18)
        uint256 liquidationThreshold; // e.g. 0.8e18 = 80%, in wad
        uint256 liquidationBonus; // e.g. 1.05e18 = 5% bonus, in wad
        uint256 reserveFactor; // share of interest kept by protocol (wad)
        address interestRateModel;
    }

    struct ReserveData {
        uint256 totalDeposits;
        uint256 totalBorrows;
    }

    struct UserReserveData {
        uint256 depositBalance;
        uint256 borrowBalance;
        bool useAsCollateral;
    }

    address public immutable owner;
    uint256 public immutable WAD = 1e18;

    // Asset => config & state
    mapping(address => ReserveConfig) public reserveConfigs;
    mapping(address => ReserveData) public reserveData;

    // Asset list
    address[] public reservesList;

    // Simple admin-set price oracle: asset => price in ETH (wad)
    mapping(address => uint256) public assetPricesInEth;

    // user => asset => data
    mapping(address => mapping(address => UserReserveData)) public userReserves;

    event ReserveInitialized(address indexed asset, ReserveConfig config);
    event ReserveConfigUpdated(address indexed asset, ReserveConfig config);
    event Deposit(address indexed user, address indexed asset, uint256 amount);
    event Withdraw(address indexed user, address indexed asset, uint256 amount);
    event Borrow(address indexed user, address indexed asset, uint256 amount, uint256 rate);
    event Repay(address indexed user, address indexed asset, uint256 amount);
    event LiquidationCall(
        address indexed liquidator,
        address indexed user,
        address indexed collateralAsset,
        address debtAsset,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }

    modifier reserveIsActive(address asset) {
        require(reserveConfigs[asset].isActive, "RESERVE_INACTIVE");
        require(!reserveConfigs[asset].isFrozen, "RESERVE_FROZEN");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // -----------------------
    // Admin functions
    // -----------------------

    function initReserve(
        address asset,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 reserveFactor,
        address interestRateModel
    ) external onlyOwner {
        require(asset != address(0), "INVALID_ASSET");
        require(!reserveConfigs[asset].isActive, "ALREADY_INITIALIZED");
        require(collateralFactor <= liquidationThreshold, "BAD_CF_LT");
        require(liquidationBonus >= WAD, "BAD_LIQ_BONUS");

        ReserveConfig memory config = ReserveConfig({
            isActive: true,
            isFrozen: false,
            collateralFactor: collateralFactor,
            liquidationThreshold: liquidationThreshold,
            liquidationBonus: liquidationBonus,
            reserveFactor: reserveFactor,
            interestRateModel: interestRateModel
        });

        reserveConfigs[asset] = config;
        reservesList.push(asset);

        emit ReserveInitialized(asset, config);
    }

    function setReserveConfig(
        address asset,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 reserveFactor,
        address interestRateModel
    ) external onlyOwner {
        ReserveConfig storage cfg = reserveConfigs[asset];
        require(cfg.isActive, "NOT_INITIALIZED");

        require(collateralFactor <= liquidationThreshold, "BAD_CF_LT");
        require(liquidationBonus >= WAD, "BAD_LIQ_BONUS");

        cfg.collateralFactor = collateralFactor;
        cfg.liquidationThreshold = liquidationThreshold;
        cfg.liquidationBonus = liquidationBonus;
        cfg.reserveFactor = reserveFactor;
        cfg.interestRateModel = interestRateModel;

        emit ReserveConfigUpdated(asset, cfg);
    }

    function setReserveActive(address asset, bool active) external onlyOwner {
        reserveConfigs[asset].isActive = active;
    }

    function setReserveFrozen(address asset, bool frozen) external onlyOwner {
        reserveConfigs[asset].isFrozen = frozen;
    }

    function setAssetPrice(address asset, uint256 priceInEth) external onlyOwner {
        // priceInEth is in wad, e.g. 1 ETH = 1e18, 0.5 ETH = 5e17
        require(asset != address(0), "INVALID_ASSET");
        assetPricesInEth[asset] = priceInEth;
    }

    // -----------------------
    // User-facing functions
    // -----------------------

    /// @notice Deposit `amount` of `asset` into the pool.
    function deposit(address asset, uint256 amount, bool useAsCollateral) external reserveIsActive(asset) {
        require(amount > 0, "INVALID_AMOUNT");

        IERC20 token = IERC20(asset);
        require(token.transferFrom(msg.sender, address(this), amount), "TRANSFER_FAILED");

        ReserveData storage rd = reserveData[asset];
        UserReserveData storage urd = userReserves[msg.sender][asset];

        rd.totalDeposits += amount;
        urd.depositBalance += amount;

        if (useAsCollateral) {
            urd.useAsCollateral = true;
        }

        emit Deposit(msg.sender, asset, amount);
    }

    /// @notice Withdraw up to your deposit balance.
    function withdraw(address asset, uint256 amount) external reserveIsActive(asset) {
        UserReserveData storage urd = userReserves[msg.sender][asset];
        require(amount > 0 && amount <= urd.depositBalance, "INVALID_AMOUNT");

        // Temporarily update balances to run health check.
        urd.depositBalance -= amount;
        ReserveData storage rd = reserveData[asset];
        rd.totalDeposits -= amount;

        // Ensure user remains healthy after withdrawal.
        _ensureHealthy(msg.sender);

        IERC20 token = IERC20(asset);
        require(token.transfer(msg.sender, amount), "TRANSFER_FAILED");

        emit Withdraw(msg.sender, asset, amount);
    }

    /// @notice Borrow `amount` of `asset`.
    function borrow(address asset, uint256 amount) external reserveIsActive(asset) {
        require(amount > 0, "INVALID_AMOUNT");

        ReserveConfig storage cfg = reserveConfigs[asset];
        ReserveData storage rd = reserveData[asset];
        UserReserveData storage urd = userReserves[msg.sender][asset];

        require(assetPricesInEth[asset] > 0, "NO_PRICE");

        // Compute variable borrow rate using current utilization.
        uint256 variableRate = InterestRateModel(cfg.interestRateModel).getVariableBorrowRate(
            rd.totalDeposits,
            rd.totalBorrows
        );

        // For simplicity, interest accrual is not implemented over time here.
        // The borrow balance is just principal. You can extend this to add
        // indexes and time-based accrual like Aave/Compound.

        rd.totalBorrows += amount;
        urd.borrowBalance += amount;

        // Health factor check after adding debt.
        _ensureHealthy(msg.sender);

        IERC20 token = IERC20(asset);
        require(token.transfer(msg.sender, amount), "TRANSFER_FAILED");

        emit Borrow(msg.sender, asset, amount, variableRate);
    }

    /// @notice Repay your variable debt.
    function repay(address asset, uint256 amount) external reserveIsActive(asset) {
        require(amount > 0, "INVALID_AMOUNT");

        ReserveData storage rd = reserveData[asset];
        UserReserveData storage urd = userReserves[msg.sender][asset];

        uint256 debt = urd.borrowBalance;
        require(debt > 0, "NO_DEBT");

        uint256 payAmount = amount > debt ? debt : amount;

        IERC20 token = IERC20(asset);
        require(token.transferFrom(msg.sender, address(this), payAmount), "TRANSFER_FAILED");

        urd.borrowBalance -= payAmount;
        rd.totalBorrows -= payAmount;

        emit Repay(msg.sender, asset, payAmount);
    }

    /// @notice Liquidate an undercollateralized position.
    /// @param collateralAsset The asset used as collateral
    /// @param debtAsset The asset the user has borrowed
    /// @param user The user being liquidated
    /// @param debtToCover Amount of debt to repay on behalf of the user
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover
    ) external reserveIsActive(collateralAsset) reserveIsActive(debtAsset) {
        require(debtToCover > 0, "INVALID_AMOUNT");

        // Check that user is currently unhealthy.
        require(!_isHealthy(user), "USER_HEALTHY");

        UserReserveData storage collateralURD = userReserves[user][collateralAsset];
        UserReserveData storage debtURD = userReserves[user][debtAsset];

        uint256 userDebt = debtURD.borrowBalance;
        require(userDebt > 0, "NO_DEBT");

        uint256 actualDebtToCover = debtToCover > userDebt ? userDebt : debtToCover;

        // Liquidator transfers debtAsset to the pool.
        IERC20(debtAsset).transferFrom(msg.sender, address(this), actualDebtToCover);

        // Reduce user's debt.
        debtURD.borrowBalance -= actualDebtToCover;
        reserveData[debtAsset].totalBorrows -= actualDebtToCover;

        // Compute how much collateral to seize based on prices.
        uint256 collateralPrice = assetPricesInEth[collateralAsset];
        uint256 debtPrice = assetPricesInEth[debtAsset];
        require(collateralPrice > 0 && debtPrice > 0, "NO_PRICE");

        ReserveConfig storage colCfg = reserveConfigs[collateralAsset];

        // collateralSeized = debtToCover * debtPrice / collateralPrice * liquidationBonus
        uint256 collateralSeized = (((actualDebtToCover * debtPrice) / collateralPrice) *
            colCfg.liquidationBonus) / WAD;

        require(collateralSeized <= collateralURD.depositBalance, "NOT_ENOUGH_COLLATERAL");

        collateralURD.depositBalance -= collateralSeized;
        reserveData[collateralAsset].totalDeposits -= collateralSeized;

        // Transfer seized collateral to liquidator.
        IERC20(collateralAsset).transfer(msg.sender, collateralSeized);

        emit LiquidationCall(
            msg.sender,
            user,
            collateralAsset,
            debtAsset,
            actualDebtToCover,
            collateralSeized
        );
    }

    // -----------------------
    // View helpers
    // -----------------------

    function getReservesList() external view returns (address[] memory) {
        return reservesList;
    }

    /// @notice Returns total collateral, total debt, and health factor for a user.
    /// @dev This is heavily simplified and uses admin-set prices.
    function getUserAccountData(
        address user
    ) external view returns (uint256 totalCollateralEth, uint256 totalDebtEth, uint256 healthFactor) {
        (totalCollateralEth, totalDebtEth, healthFactor) = _calculateAccountData(user);
    }

    // -----------------------
    // Internal logic
    // -----------------------

    function _ensureHealthy(address user) internal view {
        require(_isHealthy(user), "HF_LT_1");
    }

    function _isHealthy(address user) internal view returns (bool) {
        (, , uint256 hf) = _calculateAccountData(user);
        // health factor is scaled by 1e18; unhealthy if < 1e18
        return hf >= WAD;
    }

    function _calculateAccountData(
        address user
    ) internal view returns (uint256 totalCollateralEth, uint256 totalDebtEth, uint256 healthFactor) {
        uint256 len = reservesList.length;

        for (uint256 i = 0; i < len; i++) {
            address asset = reservesList[i];
            ReserveConfig storage cfg = reserveConfigs[asset];
            UserReserveData storage urd = userReserves[user][asset];

            uint256 priceInEth = assetPricesInEth[asset];
            if (priceInEth == 0) continue;

            if (urd.useAsCollateral && urd.depositBalance > 0 && cfg.isActive) {
                uint256 collateralEth = (urd.depositBalance * priceInEth) / WAD;
                totalCollateralEth += (collateralEth * cfg.collateralFactor) / WAD;
            }

            if (urd.borrowBalance > 0) {
                uint256 debtEth = (urd.borrowBalance * priceInEth) / WAD;
                totalDebtEth += debtEth;
            }
        }

        if (totalDebtEth == 0) {
            // Max health factor if no debt
            healthFactor = type(uint256).max;
        } else {
            // HF = totalCollateralEth / totalDebtEth
            healthFactor = (totalCollateralEth * WAD) / totalDebtEth;
        }
    }
}

