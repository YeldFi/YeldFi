// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./YeldFiVault.sol";
import "./YeldFiStrategy.sol";
import "./interfaces/IERC20.sol";

/**
 * @title YeldFiFactory
 * @dev Factory contract for deploying YeldFi vaults and strategies
 */
contract YeldFiFactory {
    address public owner;
    uint256 public vaultCount;
    
    // Default protocol addresses (can be updated)
    address public defaultAaveLendingPool;
    address public defaultCompoundToken;
    address public defaultAaveToken;
    
    struct VaultInfo {
        address vault;
        address strategy;
        address asset;
        string name;
        string symbol;
        uint256 createdAt;
        address creator;
    }
    
    mapping(uint256 => VaultInfo) public vaults;
    mapping(address => uint256[]) public userVaults;
    
    event VaultCreated(
        uint256 indexed vaultId,
        address indexed vault,
        address indexed strategy,
        address asset,
        string name,
        string symbol,
        address creator
    );
    
    event DefaultAddressesUpdated(
        address aaveLendingPool,
        address compoundToken,
        address aaveToken
    );
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    constructor(
        address _aaveLendingPool,
        address _compoundToken,
        address _aaveToken
    ) {
        owner = msg.sender;
        defaultAaveLendingPool = _aaveLendingPool;
        defaultCompoundToken = _compoundToken;
        defaultAaveToken = _aaveToken;
    }
    
    /**
     * @dev Creates a new YeldFi vault with associated strategy
     * @param _name Name of the vault token
     * @param _symbol Symbol of the vault token
     * @param _asset Asset token address
     * @return vaultAddress Address of created vault
     * @return strategyAddress Address of created strategy
     */
    function createVault(
        string memory _name,
        string memory _symbol,
        address _asset
    ) external returns (address vaultAddress, address strategyAddress) {
        require(_asset != address(0), "Invalid asset");
        require(bytes(_name).length > 0, "Empty name");
        require(bytes(_symbol).length > 0, "Empty symbol");
        
        // Deploy strategy first
        YeldFiStrategy strategy = new YeldFiStrategy(
            _asset,
            address(0), // Will be set after vault deployment
            defaultAaveLendingPool,
            defaultCompoundToken,
            defaultAaveToken
        );
        
        // Deploy vault
        YeldFiVault vault = new YeldFiVault(
            _name,
            _symbol,
            IERC20(_asset),
            address(strategy)
        );
        
        // Update strategy with vault address
        // Note: This would require a setter function in strategy or different architecture
        
        vaultAddress = address(vault);
        strategyAddress = address(strategy);
        
        // Store vault info
        VaultInfo memory vaultInfo = VaultInfo({
            vault: vaultAddress,
            strategy: strategyAddress,
            asset: _asset,
            name: _name,
            symbol: _symbol,
            createdAt: block.timestamp,
            creator: msg.sender
        });
        
        vaults[vaultCount] = vaultInfo;
        userVaults[msg.sender].push(vaultCount);
        
        emit VaultCreated(
            vaultCount,
            vaultAddress,
            strategyAddress,
            _asset,
            _name,
            _symbol,
            msg.sender
        );
        
        vaultCount++;
    }
    
    /**
     * @dev Get vault information by ID
     */
    function getVaultInfo(uint256 vaultId) external view returns (VaultInfo memory) {
        require(vaultId < vaultCount, "Invalid vault ID");
        return vaults[vaultId];
    }
    
    /**
     * @dev Get all vault IDs created by a user
     */
    function getUserVaults(address user) external view returns (uint256[] memory) {
        return userVaults[user];
    }
    
    /**
     * @dev Get vault statistics
     */
    function getVaultStats(uint256 vaultId) external view returns (
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 aavePercent,
        uint256 compoundPercent,
        IYeldFiStrategy.RiskProfile riskProfile
    ) {
        require(vaultId < vaultCount, "Invalid vault ID");
        
        VaultInfo memory vaultInfo = vaults[vaultId];
        YeldFiVault vault = YeldFiVault(vaultInfo.vault);
        YeldFiStrategy strategy = YeldFiStrategy(vaultInfo.strategy);
        
        totalAssets = vault.totalAssets();
        totalSupply = vault.totalSupply();
        (aavePercent, compoundPercent) = strategy.getCurrentAllocation();
        riskProfile = strategy.getRiskProfile();
    }
    
    /**
     * @dev Update default protocol addresses
     */
    function updateDefaultAddresses(
        address _aaveLendingPool,
        address _compoundToken,
        address _aaveToken
    ) external onlyOwner {
        defaultAaveLendingPool = _aaveLendingPool;
        defaultCompoundToken = _compoundToken;
        defaultAaveToken = _aaveToken;
        
        emit DefaultAddressesUpdated(_aaveLendingPool, _compoundToken, _aaveToken);
    }
    
    /**
     * @dev Transfer ownership
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }
    
    /**
     * @dev Get all vaults (paginated)
     */
    function getAllVaults(uint256 offset, uint256 limit) 
        external 
        view 
        returns (VaultInfo[] memory vaultInfos) 
    {
        require(offset < vaultCount, "Offset too high");
        
        uint256 end = offset + limit;
        if (end > vaultCount) {
            end = vaultCount;
        }
        
        vaultInfos = new VaultInfo[](end - offset);
        
        for (uint256 i = offset; i < end; i++) {
            vaultInfos[i - offset] = vaults[i];
        }
    }
} 