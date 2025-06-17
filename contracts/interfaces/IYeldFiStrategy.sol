// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IYeldFiStrategy
 * @dev Interface for YeldFi strategy contracts
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

    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external returns (uint256);
    function rebalance() external;
    function setRiskProfile(RiskProfile profile) external;
    function totalAssets() external view returns (uint256);
    function getRiskProfile() external view returns (RiskProfile);
    function emergencyWithdraw() external;
} 