const { ethers } = require("hardhat");

// Mainnet addresses (you may need to update these)
const MAINNET_ADDRESSES = {
  USDC: "0xA0b86a33E6417db4c4e8AC1C2A8b6b6a0Cc58C0e7", // USDC
  AAVE_LENDING_POOL: "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9",
  COMPOUND_CUSDC: "0x39AA39c021dfbaE8faC545936693aC917d5E7563",
  AAVE_AUSDC: "0xBcca60bB61934080951369a648Fb03DF4F96263C"
};

// Sepolia testnet addresses (example - you may need to find actual testnet addresses)
const SEPOLIA_ADDRESSES = {
  USDC: "0x...", // Mock USDC for testing
  AAVE_LENDING_POOL: "0x...",
  COMPOUND_CUSDC: "0x...",
  AAVE_AUSDC: "0x..."
};

async function main() {
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  
  console.log("🚀 Deploying YeldFi contracts...");
  console.log("📍 Network:", network.name);
  console.log("👤 Deployer:", deployer.address);
  console.log("💰 Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");
  
  // Select addresses based on network
  let addresses;
  if (network.chainId === 1n) { // Mainnet
    addresses = MAINNET_ADDRESSES;
  } else if (network.chainId === 11155111n) { // Sepolia
    addresses = SEPOLIA_ADDRESSES;
  } else {
    // For local testing, deploy mock contracts
    console.log("🔧 Deploying mock contracts for local testing...");
    addresses = await deployMockContracts();
  }
  
  console.log("📄 Using addresses:", addresses);
  
  // Deploy Factory
  console.log("\n📦 Deploying YeldFiFactory...");
  const YeldFiFactory = await ethers.getContractFactory("YeldFiFactory");
  const factory = await YeldFiFactory.deploy(
    addresses.AAVE_LENDING_POOL,
    addresses.COMPOUND_CUSDC,
    addresses.AAVE_AUSDC
  );
  await factory.waitForDeployment();
  
  console.log("✅ YeldFiFactory deployed to:", await factory.getAddress());
  
  // Create a sample vault for USDC
  console.log("\n🏦 Creating sample USDC vault...");
  const tx = await factory.createVault(
    "YeldFi USDC Vault",
    "yUSDC",
    addresses.USDC
  );
  
  const receipt = await tx.wait();
  console.log("✅ Sample vault created!");
  
  // Get vault info
  const vaultInfo = await factory.getVaultInfo(0);
  console.log("📊 Vault Address:", vaultInfo.vault);
  console.log("📊 Strategy Address:", vaultInfo.strategy);
  
  // Save deployment info
  const deploymentInfo = {
    network: network.name,
    chainId: network.chainId.toString(),
    deployer: deployer.address,
    contracts: {
      factory: await factory.getAddress(),
      sampleVault: vaultInfo.vault,
      sampleStrategy: vaultInfo.strategy
    },
    addresses: addresses,
    timestamp: new Date().toISOString()
  };
  
  console.log("\n📋 Deployment Summary:");
  console.log(JSON.stringify(deploymentInfo, null, 2));
  
  // Verify contracts on Etherscan if not local network
  if (network.chainId !== 31337n) {
    console.log("\n🔍 Verifying contracts on Etherscan...");
    try {
      await hre.run("verify:verify", {
        address: await factory.getAddress(),
        constructorArguments: [
          addresses.AAVE_LENDING_POOL,
          addresses.COMPOUND_CUSDC,
          addresses.AAVE_AUSDC
        ],
      });
    } catch (error) {
      console.log("❌ Verification failed:", error.message);
    }
  }
  
  console.log("\n🎉 Deployment completed successfully!");
}

async function deployMockContracts() {
  console.log("Deploying mock ERC20 token...");
  
  // Deploy a simple mock ERC20 for testing
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const mockUSDC = await MockERC20.deploy("Mock USDC", "mUSDC", 6);
  await mockUSDC.waitForDeployment();
  
  console.log("✅ Mock USDC deployed to:", await mockUSDC.getAddress());
  
  return {
    USDC: await mockUSDC.getAddress(),
    AAVE_LENDING_POOL: ethers.ZeroAddress, // Mock address
    COMPOUND_CUSDC: ethers.ZeroAddress,     // Mock address
    AAVE_AUSDC: ethers.ZeroAddress          // Mock address
  };
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  }); 