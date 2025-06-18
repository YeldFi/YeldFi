// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IYeldFiStrategy.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IProtocol.sol";

/**
 * @title YeldFiStrategy
 * @dev Strategy contract that manages allocation between Aave and Compound with auto-compound functionality
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
    
    // Auto-compound configuration
    uint256 public minCompoundAmount = 10e18; // Minimum amount to trigger auto-compound
    uint256 public lastCompoundTimestamp;
    uint256 public constant COMPOUND_COOLDOWN = 1 hours; // Minimum time between compounds
    uint256 public totalCompoundedRewards;
    bool public autoCompoundEnabled = true;
    
    // Rewards tracking
    mapping(address => uint256) public lastRewardsClaim;
    uint256 public totalRewardsClaimed;
    uint256 public performanceFeeCompound = 50; // 0.5% performance fee on auto-compound (5000 = 50%)
    uint256 public constant FEE_PRECISION = 10000;
    
    // Risk profile allocations (basis points - 10000 = 100%)
    mapping(RiskProfile => uint256) public aaveAllocation;
    mapping(RiskProfile => uint256) public compoundAllocation;
    
    // Slippage protection (basis points)
    uint256 public constant MAX_SLIPPAGE = 100; // 1%
    uint256 public constant SLIPPAGE_PRECISION = 10000;
    
    // Events for auto-compound
    event AutoCompound(uint256 rewardsAmount, uint256 compoundedAmount, uint256 feeAmount, uint256 timestamp);
    event AutoCompoundConfigChanged(uint256 minAmount, bool enabled, uint256 timestamp);
    event RewardsClaimed(address indexed protocol, uint256 amount, uint256 timestamp);
    
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
        
        // Auto-compound before rebalancing if enabled
        if (autoCompoundEnabled) {
            autoCompound();
        }
        
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
    
    /**
     * @dev Auto-compound accumulated rewards from protocols
     * @notice Can be called by anyone (keeper job) or automatically during rebalance
     * @return compoundedAmount Amount of rewards that were compounded
     */
    function autoCompound() public returns (uint256 compoundedAmount) {
        require(autoCompoundEnabled, "Auto-compound disabled");
        require(
            block.timestamp >= lastCompoundTimestamp + COMPOUND_COOLDOWN,
            "Compound cooldown active"
        );
        
        // Claim rewards from both protocols
        uint256 totalRewards = _claimAllRewards();
        
        if (totalRewards < minCompoundAmount) {
            return 0;
        }
        
        // Calculate performance fee
        uint256 feeAmount = 0;
        if (performanceFeeCompound > 0) {
            feeAmount = (totalRewards * performanceFeeCompound) / FEE_PRECISION;
            // Send fee to vault (vault owner can collect fees)
            if (feeAmount > 0) {
                asset.transfer(vault, feeAmount);
            }
        }
        
        // Compound the remaining rewards
        compoundedAmount = totalRewards - feeAmount;
        
        if (compoundedAmount > 0) {
            // Deposit according to current risk allocation
            uint256 aaveAmount = (compoundedAmount * aaveAllocation[riskProfile]) / 10000;
            uint256 compoundAmount = compoundedAmount - aaveAmount;
            
            if (aaveAmount > 0) {
                _depositToAave(aaveAmount);
            }
            
            if (compoundAmount > 0) {
                _depositToCompound(compoundAmount);
            }
            
            // Update tracking
            totalCompoundedRewards += compoundedAmount;
            lastCompoundTimestamp = block.timestamp;
            
            emit AutoCompound(totalRewards, compoundedAmount, feeAmount);
        }
        
        return compoundedAmount;
    }
    
    /**
     * @dev Claim rewards from all protocols
     * @return totalRewards Total amount of rewards claimed
     */
    function claimRewards() external returns (uint256 totalRewards) {
        totalRewards = _claimAllRewards();
        if (totalRewards > 0) {
            // Transfer rewards to vault for manual handling
            asset.transfer(vault, totalRewards);
        }
        return totalRewards;
    }
    
    /**
     * @dev Get pending rewards from all protocols
     * @return aaveRewards Pending rewards from Aave
     * @return compoundRewards Pending rewards from Compound
     */
    function getPendingRewards() external view returns (uint256 aaveRewards, uint256 compoundRewards) {
        aaveRewards = _getAavePendingRewards();
        compoundRewards = _getCompoundPendingRewards();
    }
    
    /**
     * @dev Set auto-compound configuration (only owner)
     * @param _minCompoundAmount Minimum reward amount to trigger auto-compound
     * @param _enabled Whether auto-compound is enabled
     */
    function setAutoCompoundConfig(uint256 _minCompoundAmount, bool _enabled) external onlyOwner {
        minCompoundAmount = _minCompoundAmount;
        autoCompoundEnabled = _enabled;
        emit AutoCompoundConfigChanged(_minCompoundAmount, _enabled);
    }
    
    /**
     * @dev Set performance fee for auto-compound (only owner)
     * @param _performanceFee Performance fee in basis points (max 500 = 5%)
     */
    function setPerformanceFeeCompound(uint256 _performanceFee) external onlyOwner {
        require(_performanceFee <= 500, "Fee too high"); // Max 5%
        performanceFeeCompound = _performanceFee;
    }
    
    /**
     * @dev Internal function to claim rewards from all protocols
     * @return totalRewards Total rewards claimed
     */
    function _claimAllRewards() internal returns (uint256 totalRewards) {
        uint256 aaveRewards = _claimAaveRewards();
        uint256 compoundRewards = _claimCompoundRewards();
        
        totalRewards = aaveRewards + compoundRewards;
        totalRewardsClaimed += totalRewards;
        
        return totalRewards;
    }
    
    /**
     * @dev Claim rewards from Aave protocol
     * @return rewardsAmount Amount of rewards claimed
     */
    function _claimAaveRewards() internal returns (uint256 rewardsAmount) {
        try aaveToken.getRewards() returns (uint256 rewards) {
            if (rewards > 0) {
                emit RewardsClaimed(address(aaveLendingPool), rewards);
                return rewards;
            }
        } catch {
            // Some Aave versions may not have direct reward claiming
            // In that case, rewards are automatically compounded
        }
        return 0;
    }
    
    /**
     * @dev Claim rewards from Compound protocol
     * @return rewardsAmount Amount of rewards claimed
     */
    function _claimCompoundRewards() internal returns (uint256 rewardsAmount) {
        try compoundToken.claimComp(address(this)) returns (uint256 rewards) {
            if (rewards > 0) {
                emit RewardsClaimed(address(compoundToken), rewards);
                return rewards;
            }
        } catch {
            // Handle case where COMP rewards are not available
        }
        return 0;
    }
    
    /**
     * @dev Get pending Aave rewards
     * @return pendingRewards Amount of pending rewards
     */
    function _getAavePendingRewards() internal view returns (uint256 pendingRewards) {
        try aaveToken.getUnclaimedRewards(address(this)) returns (uint256 rewards) {
            return rewards;
        } catch {
            return 0;
        }
    }
    
    /**
     * @dev Get pending Compound rewards
     * @return pendingRewards Amount of pending rewards
     */
    function _getCompoundPendingRewards() internal view returns (uint256 pendingRewards) {
        try compoundToken.getCompAccrued(address(this)) returns (uint256 rewards) {
            return rewards;
        } catch {
            return 0;
        }
    }
    
    /**
     * @dev Get auto-compound statistics
     * @return totalCompounded Total amount compounded so far
     * @return lastCompoundTime Last time auto-compound was executed
     * @return isEnabled Whether auto-compound is enabled
     * @return minAmount Minimum amount to trigger auto-compound
     */
    function getAutoCompoundStats() external view returns (
        uint256 totalCompounded,
        uint256 lastCompoundTime,
        bool isEnabled,
        uint256 minAmount
    ) {
        return (
            totalCompoundedRewards,
            lastCompoundTimestamp,
            autoCompoundEnabled,
            minCompoundAmount
        );
    }
    
    /**
     * @dev Get total rewards claimed so far
     * @return totalClaimed Total amount of rewards claimed
     */
    function getTotalRewardsClaimed() external view returns (uint256 totalClaimed) {
        return totalRewardsClaimed;
    }
    
    /**
     * @dev Check if auto-compound can be executed
     * @return canExecute Whether auto-compound can be executed now
     * @return pendingAmount Amount of pending rewards
     * @return timeLeft Time left until cooldown expires (0 if ready)
     */
    function canAutoCompound() external view returns (
        bool canExecute,
        uint256 pendingAmount,
        uint256 timeLeft
    ) {
        if (!autoCompoundEnabled) {
            return (false, 0, 0);
        }
        
        // Check cooldown
        uint256 nextCompoundTime = lastCompoundTimestamp + COMPOUND_COOLDOWN;
        if (block.timestamp < nextCompoundTime) {
            return (false, 0, nextCompoundTime - block.timestamp);
        }
        
        // Check pending rewards
        (uint256 aaveRewards, uint256 compoundRewards) = (
            _getAavePendingRewards(),
            _getCompoundPendingRewards()
        );
        pendingAmount = aaveRewards + compoundRewards;
        
        canExecute = pendingAmount >= minCompoundAmount;
        return (canExecute, pendingAmount, 0);
    }
} 
