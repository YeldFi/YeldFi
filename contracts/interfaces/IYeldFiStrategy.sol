// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IYeldFiStrategy
 * @dev Interface for YeldFi strategy contracts with auto-compound functionality
 */
interface IYeldFiStrategy {
    enum RiskProfile {
        LOW,    // 80% Aave / 20% Compound
        MEDIUM, // 50% Aave / 50% Compound
        HIGH    // 20% Aave / 80% Compound
    }

    event Rebalanced(uint256 aaveAmount, uint256 compoundAmount);
    event RiskProfileChanged(RiskProfile newProfile);
    event EmergencyWithdraw(uint256 amount);
    event AutoCompound(uint256 rewardsAmount, uint256 compoundedAmount, uint256 feeAmount);
    event AutoCompoundConfigChanged(uint256 minAmount, bool enabled);
    event RewardsClaimed(address indexed protocol, uint256 amount);

    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external returns (uint256);
    function rebalance() external;
    function setRiskProfile(RiskProfile profile) external;
    function totalAssets() external view returns (uint256);
    function getRiskProfile() external view returns (RiskProfile);
    function emergencyWithdraw() external;
    function autoCompound() external returns (uint256 compoundedAmount);
    function claimRewards() external returns (uint256 totalRewards);
    function getPendingRewards() external view returns (uint256 aaveRewards, uint256 compoundRewards);
    function setAutoCompoundConfig(uint256 _minCompoundAmount, bool _enabled) external;
    function setPerformanceFeeCompound(uint256 _performanceFee) external;
    
    // Auto-compound view functions
    function getAutoCompoundStats() external view returns (
        uint256 totalCompounded,
        uint256 lastCompoundTime,
        bool isEnabled,
        uint256 minAmount
    );
    function getTotalRewardsClaimed() external view returns (uint256 totalClaimed);
    function canAutoCompound() external view returns (
        bool canExecute,
        uint256 pendingAmount,
        uint256 timeLeft
    );
} 
