// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IYeldFiStrategy.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IProtocol.sol";

/**
 * @title YeldFiStrategy
 * @dev Strategy contract that manages allocation between Aave and Compound
 */
contract YeldFiStrategy is IYeldFiStrategy {
    IERC20 public immutable asset;
    address public immutable vault;
    address public owner;
    
    // Protocol interfaces
    ILendingPool public aaveLendingPool;
    ICToken public compoundToken;
    IAToken public aaveToken;
    
    // Risk management
    RiskProfile public riskProfile = RiskProfile.MEDIUM;
    uint256 public lastRebalanceTimestamp;
    uint256 public constant REBALANCE_COOLDOWN = 6 hours;
    
    // Risk profile allocations (basis points - 10000 = 100%)
    mapping(RiskProfile => uint256) public aaveAllocation;
    mapping(RiskProfile => uint256) public compoundAllocation;
    
    // Slippage protection (basis points)
    uint256 public constant MAX_SLIPPAGE = 100; // 1%
    uint256 public constant SLIPPAGE_PRECISION = 10000;
    
    modifier onlyVault() {
        require(msg.sender == vault, "Not vault");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    constructor(
        address _asset,
        address _vault,
        address _aaveLendingPool,
        address _compoundToken,
        address _aaveToken
    ) {
        asset = IERC20(_asset);
        vault = _vault;
        owner = msg.sender;
        
        aaveLendingPool = ILendingPool(_aaveLendingPool);
        compoundToken = ICToken(_compoundToken);
        aaveToken = IAToken(_aaveToken);
        
        // Initialize risk allocations
        // LOW: 80% Aave / 20% Compound
        aaveAllocation[RiskProfile.LOW] = 8000;
        compoundAllocation[RiskProfile.LOW] = 2000;
        
        // MEDIUM: 50% Aave / 50% Compound
        aaveAllocation[RiskProfile.MEDIUM] = 5000;
        compoundAllocation[RiskProfile.MEDIUM] = 5000;
        
        // HIGH: 20% Aave / 80% Compound
        aaveAllocation[RiskProfile.HIGH] = 2000;
        compoundAllocation[RiskProfile.HIGH] = 8000;
        
        lastRebalanceTimestamp = block.timestamp;
    }
    
    function deposit(uint256 amount) external override onlyVault {
        require(amount > 0, "Cannot deposit 0");
        
        asset.transferFrom(msg.sender, address(this), amount);
        
        // Allocate according to current risk profile
        uint256 aaveAmount = (amount * aaveAllocation[riskProfile]) / 10000;
        uint256 compoundAmount = amount - aaveAmount;
        
        if (aaveAmount > 0) {
            _depositToAave(aaveAmount);
        }
        
        if (compoundAmount > 0) {
            _depositToCompound(compoundAmount);
        }
    }
    
    function withdraw(uint256 amount) external override onlyVault returns (uint256) {
        require(amount > 0, "Cannot withdraw 0");
        
        uint256 totalAssets_ = totalAssets();
        require(amount <= totalAssets_, "Insufficient assets");
        
        // Calculate proportional withdrawal from each protocol
        uint256 aaveBalance = _getAaveBalance();
        uint256 compoundBalance = _getCompoundBalance();
        
        uint256 aaveWithdraw = 0;
        uint256 compoundWithdraw = 0;
        
        if (totalAssets_ > 0) {
            aaveWithdraw = (amount * aaveBalance) / totalAssets_;
            compoundWithdraw = (amount * compoundBalance) / totalAssets_;
        }
        
        uint256 totalWithdrawn = 0;
        
        if (aaveWithdraw > 0) {
            totalWithdrawn += _withdrawFromAave(aaveWithdraw);
        }
        
        if (compoundWithdraw > 0) {
            totalWithdrawn += _withdrawFromCompound(compoundWithdraw);
        }
        
        // Transfer to vault
        asset.transfer(vault, totalWithdrawn);
        
        return totalWithdrawn;
    }
    
    function rebalance() external override {
        require(
            block.timestamp >= lastRebalanceTimestamp + REBALANCE_COOLDOWN,
            "Rebalance cooldown active"
        );
        
        uint256 totalAssets_ = totalAssets();
        if (totalAssets_ == 0) return;
        
        // Get current balances
        uint256 aaveBalance = _getAaveBalance();
        uint256 compoundBalance = _getCompoundBalance();
        
        // Calculate target allocations
        uint256 targetAaveBalance = (totalAssets_ * aaveAllocation[riskProfile]) / 10000;
        uint256 targetCompoundBalance = totalAssets_ - targetAaveBalance;
        
        // Calculate differences
        int256 aaveDiff = int256(targetAaveBalance) - int256(aaveBalance);
        int256 compoundDiff = int256(targetCompoundBalance) - int256(compoundBalance);
        
        // Rebalance if significant difference (> 2%)
        uint256 threshold = totalAssets_ * 200 / 10000; // 2%
        
        if (abs(aaveDiff) > threshold || abs(compoundDiff) > threshold) {
            _executeRebalance(aaveDiff, compoundDiff);
        }
        
        lastRebalanceTimestamp = block.timestamp;
        emit Rebalanced(_getAaveBalance(), _getCompoundBalance());
    }
    
    function setRiskProfile(RiskProfile profile) external override onlyOwner {
        require(profile <= RiskProfile.HIGH, "Invalid risk profile");
        riskProfile = profile;
        emit RiskProfileChanged(profile);
        
        // Trigger rebalance after risk profile change
        lastRebalanceTimestamp = 0;
    }
    
    function totalAssets() public view override returns (uint256) {
        return _getAaveBalance() + _getCompoundBalance() + asset.balanceOf(address(this));
    }
    
    function getRiskProfile() external view override returns (RiskProfile) {
        return riskProfile;
    }
    
    function emergencyWithdraw() external override onlyOwner {
        // Withdraw everything from both protocols
        uint256 aaveBalance = _getAaveBalance();
        uint256 compoundBalance = _getCompoundBalance();
        
        if (aaveBalance > 0) {
            _withdrawFromAave(aaveBalance);
        }
        
        if (compoundBalance > 0) {
            _withdrawFromCompound(compoundBalance);
        }
        
        // Transfer all assets to vault
        uint256 balance = asset.balanceOf(address(this));
        if (balance > 0) {
            asset.transfer(vault, balance);
        }
        
        emit EmergencyWithdraw(balance);
    }
    
    // View functions for yields
    function getAaveAPY() external view returns (uint256) {
        (uint256 liquidityRate,,,, ) = aaveLendingPool.getReserveData(address(asset));
        return liquidityRate;
    }
    
    function getCompoundAPY() external view returns (uint256) {
        return compoundToken.supplyRatePerBlock() * 2102400; // blocks per year
    }
    
    function getCurrentAllocation() external view returns (uint256 aavePercent, uint256 compoundPercent) {
        uint256 totalAssets_ = totalAssets();
        if (totalAssets_ == 0) {
            return (0, 0);
        }
        
        uint256 aaveBalance = _getAaveBalance();
        uint256 compoundBalance = _getCompoundBalance();
        
        aavePercent = (aaveBalance * 10000) / totalAssets_;
        compoundPercent = (compoundBalance * 10000) / totalAssets_;
    }
    
    // Internal functions
    function _depositToAave(uint256 amount) internal {
        asset.approve(address(aaveLendingPool), amount);
        aaveLendingPool.deposit(address(asset), amount, address(this), 0);
    }
    
    function _depositToCompound(uint256 amount) internal {
        asset.approve(address(compoundToken), amount);
        require(compoundToken.mint(amount) == 0, "Compound deposit failed");
    }
    
    function _withdrawFromAave(uint256 amount) internal returns (uint256) {
        return aaveLendingPool.withdraw(address(asset), amount, address(this));
    }
    
    function _withdrawFromCompound(uint256 amount) internal returns (uint256) {
        uint256 balanceBefore = asset.balanceOf(address(this));
        
        // Convert amount to cToken amount
        uint256 exchangeRate = compoundToken.exchangeRateStored();
        uint256 cTokenAmount = (amount * 1e18) / exchangeRate;
        
        require(compoundToken.redeem(cTokenAmount) == 0, "Compound withdraw failed");
        
        uint256 balanceAfter = asset.balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }
    
    function _getAaveBalance() internal view returns (uint256) {
        return aaveToken.balanceOf(address(this));
    }
    
    function _getCompoundBalance() internal view returns (uint256) {
        uint256 cTokenBalance = compoundToken.balanceOf(address(this));
        if (cTokenBalance == 0) return 0;
        
        uint256 exchangeRate = compoundToken.exchangeRateStored();
        return (cTokenBalance * exchangeRate) / 1e18;
    }
    
    function _executeRebalance(int256 aaveDiff, int256 compoundDiff) internal {
        if (aaveDiff > 0) {
            // Need to move assets to Aave
            uint256 amount = uint256(aaveDiff);
            uint256 compoundBalance = _getCompoundBalance();
            
            if (amount <= compoundBalance) {
                uint256 withdrawn = _withdrawFromCompound(amount);
                _depositToAave(withdrawn);
            }
        } else if (aaveDiff < 0) {
            // Need to move assets from Aave
            uint256 amount = uint256(-aaveDiff);
            uint256 aaveBalance = _getAaveBalance();
            
            if (amount <= aaveBalance) {
                uint256 withdrawn = _withdrawFromAave(amount);
                _depositToCompound(withdrawn);
            }
        }
    }
    
    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
    
    // Owner functions
    function updateProtocolAddresses(
        address _aaveLendingPool,
        address _compoundToken,
        address _aaveToken
    ) external onlyOwner {
        aaveLendingPool = ILendingPool(_aaveLendingPool);
        compoundToken = ICToken(_compoundToken);
        aaveToken = IAToken(_aaveToken);
    }
    
    function setRiskAllocations(
        RiskProfile profile,
        uint256 _aaveAllocation,
        uint256 _compoundAllocation
    ) external onlyOwner {
        require(_aaveAllocation + _compoundAllocation == 10000, "Invalid allocations");
        aaveAllocation[profile] = _aaveAllocation;
        compoundAllocation[profile] = _compoundAllocation;
    }
} 