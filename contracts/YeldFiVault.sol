// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IERC4626.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IYeldFiStrategy.sol";

/**
 * @title YeldFiVault
 * @dev ERC-4626 compliant vault for yield farming aggregation
 */
contract YeldFiVault is IERC4626 {
    string public name;
    string public symbol;
    uint8 public decimals;
    
    IERC20 public immutable asset_;
    IYeldFiStrategy public strategy;
    
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    
    address public owner;
    uint256 public performanceFee = 100; // 1% (10000 = 100%)
    uint256 public constant FEE_PRECISION = 10000;
    
    uint256 public lastHarvestTimestamp;
    uint256 public constant HARVEST_COOLDOWN = 1 hours;
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier onlyStrategy() {
        require(msg.sender == address(strategy), "Not strategy");
        _;
    }
    
    event StrategyChanged(address indexed oldStrategy, address indexed newStrategy);
    event PerformanceFeeChanged(uint256 newFee);
    event Harvest(uint256 profit, uint256 fee);
    
    constructor(
        string memory _name,
        string memory _symbol,
        IERC20 _asset,
        address _strategy
    ) {
        name = _name;
        symbol = _symbol;
        decimals = 18;
        asset_ = _asset;
        strategy = IYeldFiStrategy(_strategy);
        owner = msg.sender;
        lastHarvestTimestamp = block.timestamp;
    }
    
    // ERC20 functions
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }
    
    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowances[owner_][spender];
    }
    
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        
        _transfer(from, to, amount);
        _approve(from, msg.sender, currentAllowance - amount);
        
        return true;
    }
    
    // ERC4626 functions
    function asset() public view override returns (address) {
        return address(asset_);
    }
    
    function totalAssets() public view override returns (uint256) {
        return strategy.totalAssets();
    }
    
    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }
    
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }
    
    function maxDeposit(address) public view override returns (uint256) {
        return type(uint256).max;
    }
    
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return convertToShares(assets);
    }
    
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 shares = previewDeposit(assets);
        _deposit(assets, shares, receiver);
        return shares;
    }
    
    function maxMint(address) public view override returns (uint256) {
        return type(uint256).max;
    }
    
    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : (shares * totalAssets() + supply - 1) / supply;
    }
    
    function mint(uint256 shares, address receiver) public override returns (uint256) {
        uint256 assets = previewMint(shares);
        _deposit(assets, shares, receiver);
        return assets;
    }
    
    function maxWithdraw(address owner_) public view override returns (uint256) {
        return convertToAssets(balanceOf(owner_));
    }
    
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply + totalAssets() - 1) / totalAssets();
    }
    
    function withdraw(uint256 assets, address receiver, address owner_) public override returns (uint256) {
        uint256 shares = previewWithdraw(assets);
        _withdraw(assets, shares, receiver, owner_);
        return shares;
    }
    
    function maxRedeem(address owner_) public view override returns (uint256) {
        return balanceOf(owner_);
    }
    
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }
    
    function redeem(uint256 shares, address receiver, address owner_) public override returns (uint256) {
        uint256 assets = previewRedeem(shares);
        _withdraw(assets, shares, receiver, owner_);
        return assets;
    }
    
    // Internal functions
    function _deposit(uint256 assets, uint256 shares, address receiver) internal {
        require(assets > 0, "Cannot deposit 0");
        require(shares > 0, "Cannot mint 0 shares");
        
        asset_.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        
        // Transfer to strategy
        asset_.approve(address(strategy), assets);
        strategy.deposit(assets);
        
        emit Deposit(msg.sender, receiver, assets, shares);
    }
    
    function _withdraw(uint256 assets, uint256 shares, address receiver, address owner_) internal {
        require(assets > 0, "Cannot withdraw 0");
        require(shares > 0, "Cannot burn 0 shares");
        
        if (msg.sender != owner_) {
            uint256 currentAllowance = _allowances[owner_][msg.sender];
            require(currentAllowance >= shares, "ERC20: transfer amount exceeds allowance");
            _approve(owner_, msg.sender, currentAllowance - shares);
        }
        
        _burn(owner_, shares);
        
        // Withdraw from strategy
        uint256 withdrawn = strategy.withdraw(assets);
        asset_.transfer(receiver, withdrawn);
        
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }
    
    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "ERC20: mint to the zero address");
        
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    
    function _burn(address from, uint256 amount) internal {
        require(from != address(0), "ERC20: burn from the zero address");
        
        uint256 accountBalance = _balances[from];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        
        _balances[from] = accountBalance - amount;
        _totalSupply -= amount;
        
        emit Transfer(from, address(0), amount);
    }
    
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        
        _balances[from] = fromBalance - amount;
        _balances[to] += amount;
        
        emit Transfer(from, to, amount);
    }
    
    function _approve(address owner_, address spender, uint256 amount) internal {
        require(owner_ != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }
    
    // Management functions
    function setStrategy(address _newStrategy) external onlyOwner {
        require(_newStrategy != address(0), "Invalid strategy");
        
        // Emergency withdraw from old strategy
        if (address(strategy) != address(0)) {
            strategy.emergencyWithdraw();
        }
        
        address oldStrategy = address(strategy);
        strategy = IYeldFiStrategy(_newStrategy);
        
        // Deposit current balance to new strategy
        uint256 balance = asset_.balanceOf(address(this));
        if (balance > 0) {
            asset_.approve(_newStrategy, balance);
            strategy.deposit(balance);
        }
        
        emit StrategyChanged(oldStrategy, _newStrategy);
    }
    
    function setPerformanceFee(uint256 _fee) external onlyOwner {
        require(_fee <= 2000, "Fee too high"); // Max 20%
        performanceFee = _fee;
        emit PerformanceFeeChanged(_fee);
    }
    
    function setRiskProfile(IYeldFiStrategy.RiskProfile _profile) external onlyOwner {
        strategy.setRiskProfile(_profile);
    }
    
    function rebalance() external {
        require(
            block.timestamp >= lastHarvestTimestamp + HARVEST_COOLDOWN,
            "Harvest cooldown active"
        );
        
        uint256 assetsBefore = totalAssets();
        strategy.rebalance();
        uint256 assetsAfter = totalAssets();
        
        if (assetsAfter > assetsBefore) {
            uint256 profit = assetsAfter - assetsBefore;
            uint256 fee = (profit * performanceFee) / FEE_PRECISION;
            
            if (fee > 0) {
                // Mint shares to owner as performance fee
                uint256 feeShares = convertToShares(fee);
                _mint(owner, feeShares);
            }
            
            emit Harvest(profit, fee);
        }
        
        lastHarvestTimestamp = block.timestamp;
    }
    
    function emergencyWithdraw() external onlyOwner {
        strategy.emergencyWithdraw();
    }
} 