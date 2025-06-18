# YeldFi - Minimalist Yield Aggregator

🚀 **YeldFi** is a minimalist yield aggregator with dynamic risk adjustment written in Solidity. The protocol automatically distributes user deposits between multiple DeFi protocols (Aave and Compound) and periodically rebalances positions according to a specified risk profile.


## 🏗️ Architecture

The protocol consists of three main components:

### 1. YeldFiVault (ERC-4626)
- Manages user deposits and withdrawals
- Issues shares for deposited assets
- User-facing interface

### 2. YeldFiStrategy
- Manages allocation between DeFi protocols
- Dynamically rebalances according to risk profile
- Integrates with Aave and Compound

### 3. YeldFiFactory
- Factory for creating new vaults
- Centralized protocol management
- Statistics and monitoring

## 📊 Risk Profiles

| Risk Profile | Aave Allocation | Compound Allocation | Description |
|--------------|-----------------|---------------------|-------------|
| **LOW** 🟢   | 80%            | 20%                 | Conservative approach |
| **MEDIUM** 🟡| 50%            | 50%                 | Balanced approach |
| **HIGH** 🔴  | 20%            | 80%                 | Aggressive approach |

## 💰 Auto-Compound System

YeldFi features an advanced **auto-compound mechanism** that automatically reinvests protocol rewards to maximize yield efficiency.

## 🎯 Protocol Flow

### Deposit Flow:
1. User deposits assets (ETH/stablecoin) to Vault
2. Vault issues shares (ERC4626 shares) to user
3. Vault transfers funds to Strategy Contract

### Rebalance Flow:
1. Strategy Contract periodically (or via external signal) performs rebalancing
2. Checks current APY and liquidity
3. Redistributes assets according to selected risk profile

### Withdraw Flow:
1. User sends shares to Vault for redemption
2. Vault returns equivalent amount of assets to user

---
