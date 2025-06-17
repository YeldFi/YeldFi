// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILendingPool
 * @dev Simplified Aave lending pool interface
 */
interface ILendingPool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset) external view returns (
        uint256 currentLiquidityRate,
        uint256 currentVariableBorrowRate,
        uint256 currentStableBorrowRate,
        uint256 lastUpdateTimestamp,
        address aTokenAddress
    );
}

/**
 * @title ICToken
 * @dev Simplified Compound cToken interface
 */
interface ICToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function supplyRatePerBlock() external view returns (uint256);
    function underlying() external view returns (address);
}

/**
 * @title IAToken
 * @dev Simplified Aave aToken interface
 */
interface IAToken {
    function balanceOf(address user) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
} 