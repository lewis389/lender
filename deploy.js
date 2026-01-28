const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with:", deployer.address);

  // Deploy a simple interest rate model.
  // These are arbitrary demo params; tune them for your needs.
  const ONE_RAY = hre.ethers.toBigInt("1000000000000000000000000000"); // 1e27

  const baseRate = hre.ethers.toBigInt("1000000000000000000"); // 1e18 ray (~very low APR)
  const slope1 = hre.ethers.toBigInt("3000000000000000000"); // 3e18 ray
  const slope2 = hre.ethers.toBigInt("6000000000000000000"); // 6e18 ray
  const optimalUtilization = ONE_RAY / 2n; // 50%

  const InterestRateModel = await hre.ethers.getContractFactory("InterestRateModel");
  const irm = await InterestRateModel.deploy(baseRate, slope1, slope2, optimalUtilization);
  await irm.waitForDeployment();
  console.log("InterestRateModel deployed to:", await irm.getAddress());

  const LendingPool = await hre.ethers.getContractFactory("LendingPool");
  const pool = await LendingPool.deploy();
  await pool.waitForDeployment();
  console.log("LendingPool deployed to:", await pool.getAddress());

  console.log("\nNext steps:");
  console.log("- Initialize reserves via pool.initReserve(asset, collateralFactor, liquidationThreshold, liquidationBonus, reserveFactor, irm.address)");
  console.log("- Set prices via pool.setAssetPrice(asset, priceInEth)");
  console.log("- Then users can call deposit/withdraw/borrow/repay/liquidationCall.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

