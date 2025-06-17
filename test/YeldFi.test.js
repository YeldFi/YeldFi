const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("YeldFi Protocol", function () {
  let owner, user1, user2;
  let mockUSDC, factory, vault, strategy;
  let vaultContract, strategyContract;

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();

    // Deploy MockERC20 (USDC)
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20.deploy("Mock USDC", "mUSDC", 6);
    await mockUSDC.waitForDeployment();

    // Deploy Factory
    const YeldFiFactory = await ethers.getContractFactory("YeldFiFactory");
    factory = await YeldFiFactory.deploy(
      ethers.ZeroAddress, // Mock Aave
      ethers.ZeroAddress, // Mock Compound
      ethers.ZeroAddress  // Mock aToken
    );
    await factory.waitForDeployment();

    // Create vault through factory
    const tx = await factory.createVault(
      "YeldFi USDC Vault",
      "yUSDC",
      await mockUSDC.getAddress()
    );
    await tx.wait();

    // Get vault and strategy addresses
    const vaultInfo = await factory.getVaultInfo(0);
    vault = vaultInfo.vault;
    strategy = vaultInfo.strategy;

    // Get contract instances
    vaultContract = await ethers.getContractAt("YeldFiVault", vault);
    strategyContract = await ethers.getContractAt("YeldFiStrategy", strategy);

    // Mint tokens to users for testing
    await mockUSDC.mint(user1.address, ethers.parseUnits("10000", 6));
    await mockUSDC.mint(user2.address, ethers.parseUnits("5000", 6));
  });

  describe("Factory", function () {
    it("Should deploy factory correctly", async function () {
      expect(await factory.owner()).to.equal(owner.address);
      expect(await factory.vaultCount()).to.equal(1);
    });

    it("Should create vault correctly", async function () {
      const vaultInfo = await factory.getVaultInfo(0);
      expect(vaultInfo.vault).to.not.equal(ethers.ZeroAddress);
      expect(vaultInfo.strategy).to.not.equal(ethers.ZeroAddress);
      expect(vaultInfo.asset).to.equal(await mockUSDC.getAddress());
      expect(vaultInfo.name).to.equal("YeldFi USDC Vault");
      expect(vaultInfo.symbol).to.equal("yUSDC");
      expect(vaultInfo.creator).to.equal(owner.address);
    });

    it("Should track user vaults", async function () {
      const userVaults = await factory.getUserVaults(owner.address);
      expect(userVaults.length).to.equal(1);
      expect(userVaults[0]).to.equal(0);
    });
  });

  describe("Vault - ERC4626 Compliance", function () {
    it("Should have correct initial state", async function () {
      expect(await vaultContract.name()).to.equal("YeldFi USDC Vault");
      expect(await vaultContract.symbol()).to.equal("yUSDC");
      expect(await vaultContract.decimals()).to.equal(18);
      expect(await vaultContract.asset()).to.equal(await mockUSDC.getAddress());
      expect(await vaultContract.totalSupply()).to.equal(0);
      expect(await vaultContract.totalAssets()).to.equal(0);
    });

    it("Should handle deposits correctly", async function () {
      const depositAmount = ethers.parseUnits("1000", 6); // 1000 USDC
      
      // Approve and deposit
      await mockUSDC.connect(user1).approve(vault, depositAmount);
      const shares = await vaultContract.connect(user1).deposit(depositAmount, user1.address);
      
      expect(await vaultContract.balanceOf(user1.address)).to.equal(depositAmount);
      expect(await vaultContract.totalSupply()).to.equal(depositAmount);
      expect(await vaultContract.convertToAssets(depositAmount)).to.equal(depositAmount);
    });

    it("Should handle withdrawals correctly", async function () {
      const depositAmount = ethers.parseUnits("1000", 6);
      const withdrawAmount = ethers.parseUnits("500", 6);
      
      // Deposit first
      await mockUSDC.connect(user1).approve(vault, depositAmount);
      await vaultContract.connect(user1).deposit(depositAmount, user1.address);
      
      const balanceBefore = await mockUSDC.balanceOf(user1.address);
      
      // Withdraw
      await vaultContract.connect(user1).withdraw(withdrawAmount, user1.address, user1.address);
      
      const balanceAfter = await mockUSDC.balanceOf(user1.address);
      expect(balanceAfter - balanceBefore).to.equal(withdrawAmount);
      
      expect(await vaultContract.balanceOf(user1.address)).to.equal(depositAmount - withdrawAmount);
    });

    it("Should handle share conversions correctly", async function () {
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // When vault is empty, 1:1 ratio
      expect(await vaultContract.convertToShares(depositAmount)).to.equal(depositAmount);
      expect(await vaultContract.convertToAssets(depositAmount)).to.equal(depositAmount);
      
      // After deposit, should maintain ratio
      await mockUSDC.connect(user1).approve(vault, depositAmount);
      await vaultContract.connect(user1).deposit(depositAmount, user1.address);
      
      expect(await vaultContract.convertToShares(depositAmount)).to.equal(depositAmount);
      expect(await vaultContract.convertToAssets(depositAmount)).to.equal(depositAmount);
    });
  });

  describe("Strategy - Risk Management", function () {
    it("Should have correct initial risk profile", async function () {
      expect(await strategyContract.getRiskProfile()).to.equal(1); // MEDIUM
    });

    it("Should allow owner to change risk profile", async function () {
      await vaultContract.setRiskProfile(0); // LOW
      expect(await strategyContract.getRiskProfile()).to.equal(0);
      
      await vaultContract.setRiskProfile(2); // HIGH
      expect(await strategyContract.getRiskProfile()).to.equal(2);
    });

    it("Should not allow non-owner to change risk profile", async function () {
      await expect(
        vaultContract.connect(user1).setRiskProfile(0)
      ).to.be.revertedWith("Not owner");
    });

    it("Should track total assets correctly", async function () {
      expect(await strategyContract.totalAssets()).to.equal(0);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      await mockUSDC.connect(user1).approve(vault, depositAmount);
      await vaultContract.connect(user1).deposit(depositAmount, user1.address);
      
      // Note: In real implementation, assets would be in protocols
      // For testing with zero addresses, assets remain in strategy
      expect(await strategyContract.totalAssets()).to.equal(depositAmount);
    });
  });

  describe("Vault Management", function () {
    it("Should allow owner to set performance fee", async function () {
      await vaultContract.setPerformanceFee(200); // 2%
      expect(await vaultContract.performanceFee()).to.equal(200);
    });

    it("Should not allow excessive performance fee", async function () {
      await expect(
        vaultContract.setPerformanceFee(2500) // 25%
      ).to.be.revertedWith("Fee too high");
    });

    it("Should have harvest cooldown", async function () {
      await expect(
        vaultContract.rebalance()
      ).to.be.revertedWith("Harvest cooldown active");
    });
  });

  describe("Edge Cases", function () {
    it("Should prevent zero deposits", async function () {
      await expect(
        vaultContract.connect(user1).deposit(0, user1.address)
      ).to.be.revertedWith("Cannot deposit 0");
    });

    it("Should prevent zero withdrawals", async function () {
      await expect(
        vaultContract.connect(user1).withdraw(0, user1.address, user1.address)
      ).to.be.revertedWith("Cannot withdraw 0");
    });

    it("Should handle insufficient balance withdrawals", async function () {
      const depositAmount = ethers.parseUnits("1000", 6);
      const withdrawAmount = ethers.parseUnits("2000", 6);
      
      await mockUSDC.connect(user1).approve(vault, depositAmount);
      await vaultContract.connect(user1).deposit(depositAmount, user1.address);
      
      await expect(
        vaultContract.connect(user1).withdraw(withdrawAmount, user1.address, user1.address)
      ).to.be.revertedWith("Insufficient assets");
    });
  });

  describe("Multi-user scenarios", function () {
    it("Should handle multiple users correctly", async function () {
      const depositAmount1 = ethers.parseUnits("1000", 6);
      const depositAmount2 = ethers.parseUnits("500", 6);
      
      // User1 deposits
      await mockUSDC.connect(user1).approve(vault, depositAmount1);
      await vaultContract.connect(user1).deposit(depositAmount1, user1.address);
      
      // User2 deposits
      await mockUSDC.connect(user2).approve(vault, depositAmount2);
      await vaultContract.connect(user2).deposit(depositAmount2, user2.address);
      
      expect(await vaultContract.balanceOf(user1.address)).to.equal(depositAmount1);
      expect(await vaultContract.balanceOf(user2.address)).to.equal(depositAmount2);
      expect(await vaultContract.totalSupply()).to.equal(depositAmount1 + depositAmount2);
    });

    it("Should handle proportional withdrawals", async function () {
      const depositAmount1 = ethers.parseUnits("1000", 6);
      const depositAmount2 = ethers.parseUnits("500", 6);
      
      // Both users deposit
      await mockUSDC.connect(user1).approve(vault, depositAmount1);
      await vaultContract.connect(user1).deposit(depositAmount1, user1.address);
      
      await mockUSDC.connect(user2).approve(vault, depositAmount2);
      await vaultContract.connect(user2).deposit(depositAmount2, user2.address);
      
      // User1 withdraws half
      const withdrawAmount = ethers.parseUnits("500", 6);
      await vaultContract.connect(user1).withdraw(withdrawAmount, user1.address, user1.address);
      
      expect(await vaultContract.balanceOf(user1.address)).to.equal(depositAmount1 - withdrawAmount);
      expect(await vaultContract.balanceOf(user2.address)).to.equal(depositAmount2);
    });
  });
}); 