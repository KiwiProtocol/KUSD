// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IPriceFeed {
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract KUSD {
    string public name = "Kiwi USD";
    string public symbol = "KUSD";
    uint8 public decimals = 18;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    address public owner;
    bool public paused;
    
    struct Collateral {
        IERC20 token;
        uint256 ratio; // Ratio in 18 decimals
    }

    mapping(address => Collateral) public collaterals;
    IPriceFeed public priceFeed;
    uint256 public TARGET_PRICE = 1e18; // 1 USD in 18 decimals
    uint256 public bondFactor;
    uint256 public totalBonds;
    uint256 public feeRate; // Dynamic fee rate in 18 decimals

    mapping(address => uint256) private lastActionTimestamp;
    uint256 public constant COOLDOWN_PERIOD = 1 days;
    uint256 public constant LARGE_AMOUNT_THRESHOLD = 1000000e18; // 1 million tokens

    bool public emergencyShutdown;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);
    event Mint(address user, uint256 amount, address collateral);
    event Burn(address user, uint256 amount, address collateral);
    event BondCreated(address indexed user, uint256 amount);
    event BondRedeemed(address indexed user, uint256 amount);
    event BondFactorUpdated(uint256 newBondFactor);
    event CollateralAdded(address collateral, uint256 ratio);
    event CollateralRemoved(address collateral);
    event Rebase(uint256 newTotalSupply);
    event FeeRateUpdated(uint256 newFeeRate);
    event PriceFeedUpdated(address newPriceFeed);
    event TargetPriceAdjusted(uint256 newTargetPrice);
    event EmergencyShutdownSet(bool shutdown);

    constructor(address _priceFeed) {
        owner = msg.sender;
        priceFeed = IPriceFeed(_priceFeed);
        bondFactor = 1e17; // 0.1 in 18 decimals
        feeRate = 1e16; // Initial fee rate (1%)
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    modifier validCollateral(address collateral) {
        require(collaterals[collateral].ratio > 0, "Invalid collateral");
        _;
    }

    modifier cooldownCheck(uint256 amount) {
        if (amount >= LARGE_AMOUNT_THRESHOLD) {
            require(block.timestamp >= lastActionTimestamp[msg.sender] + COOLDOWN_PERIOD, "Cooldown period not elapsed");
            lastActionTimestamp[msg.sender] = block.timestamp;
        }
        _;
    }

    modifier notShutdown() {
        require(!emergencyShutdown, "Contract is in emergency shutdown");
        _;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

  function allowance(address _owner, address spender) public view returns (uint256) {
    return _allowances[_owner][spender];
}
function approve(address spender, uint256 amount) public returns (bool) {
    _approve(msg.sender, spender, amount);
    return true;
}

function transferFrom(address sender, address recipient, uint256 amount) public returns (bool) {
    _transfer(sender, recipient, amount);
    uint256 currentAllowance = _allowances[sender][msg.sender];
    require(currentAllowance >= amount, "Transfer amount exceeds allowance");
    unchecked {
        _approve(sender, msg.sender, currentAllowance - amount);
    }
    return true;
}

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "Transfer from the zero address");
        require(recipient != address(0), "Transfer to the zero address");
        require(_balances[sender] >= amount, "Transfer amount exceeds balance");
        unchecked {
            _balances[sender] = _balances[sender] - amount;
        }
        _balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "Mint to the zero address");
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "Burn from the zero address");
        require(_balances[account] >= amount, "Burn amount exceeds balance");
        unchecked {
            _balances[account] = _balances[account] - amount;
        }
        _totalSupply -= amount;
        emit Transfer(account, address(0), amount);
    }

function _approve(address _owner, address spender, uint256 amount) internal {
    require(_owner != address(0), "Approve from the zero address");
    require(spender != address(0), "Approve to the zero address");
    _allowances[_owner][spender] = amount;
    emit Approval(_owner, spender, amount);
}
    function addCollateral(address collateral, uint256 ratio) external onlyOwner {
        collaterals[collateral] = Collateral({
            token: IERC20(collateral),
            ratio: ratio
        });
        emit CollateralAdded(collateral, ratio);
    }

    function removeCollateral(address collateral) external onlyOwner {
        delete collaterals[collateral];
        emit CollateralRemoved(collateral);
    }

    function mint(uint256 amount, address collateral, uint256 maxSlippage) external validCollateral(collateral) whenNotPaused notShutdown cooldownCheck(amount) {
        uint256 currentPrice = getPrice();
        require(currentPrice <= TARGET_PRICE + maxSlippage, "Slippage too high");
        uint256 collateralAmount = amount * currentPrice / 1e18;
        collateralAmount = collateralAmount + (collateralAmount * feeRate / 1e18); // Add fee
        require(collaterals[collateral].token.transferFrom(msg.sender, address(this), collateralAmount), "Collateral transfer failed");
        _mint(msg.sender, amount);
        emit Mint(msg.sender, amount, collateral);
    }

    function burn(uint256 amount, address collateral, uint256 maxSlippage) external validCollateral(collateral) whenNotPaused notShutdown cooldownCheck(amount) {
        uint256 currentPrice = getPrice();
        require(currentPrice >= TARGET_PRICE - maxSlippage, "Slippage too high");
        _burn(msg.sender, amount);
        uint256 collateralAmount = amount * currentPrice / 1e18;
        collateralAmount = collateralAmount - (collateralAmount * feeRate / 1e18); // Subtract fee
        require(collaterals[collateral].token.transfer(msg.sender, collateralAmount), "Collateral transfer failed");
        emit Burn(msg.sender, amount, collateral);
    }

    function createBond(uint256 amount) external whenNotPaused notShutdown {
        require(getPrice() < TARGET_PRICE, "Price is not below target");
        _burn(msg.sender, amount);
        uint256 bondAmount = amount * bondFactor / 1e18;
        totalBonds += bondAmount;
        emit BondCreated(msg.sender, bondAmount);
    }

    function redeemBond(uint256 amount) external whenNotPaused notShutdown {
        require(getPrice() > TARGET_PRICE, "Price is not above target");
        require(totalBonds >= amount, "Not enough bonds to redeem");
        totalBonds -= amount;
        uint256 redeemAmount = amount * 1e18 / bondFactor;
        _mint(msg.sender, redeemAmount);
        emit BondRedeemed(msg.sender, amount);
    }

    function getPrice() public view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        require(updatedAt > block.timestamp - 1 hours, "Stale price data");
        require(price > 0, "Invalid price");
        return uint256(price) * 1e10; // Adjusting the price to 18 decimals
    }

    function getCollateralRatio(address collateral) public view validCollateral(collateral) returns (uint256) {
        uint256 collateralBalance = collaterals[collateral].token.balanceOf(address(this));
        if (_totalSupply == 0) return 0;
        return collateralBalance * 1e18 / _totalSupply;
    }

    function updateBondFactor(uint256 newBondFactor) external onlyOwner {
        bondFactor = newBondFactor;
        emit BondFactorUpdated(newBondFactor);
    }

    function rebase() external onlyOwner {
        uint256 currentPrice = getPrice();
        uint256 newTotalSupply = _totalSupply * TARGET_PRICE / currentPrice;
        _rebase(newTotalSupply);
    }

    function _rebase(uint256 newTotalSupply) internal {
        if (newTotalSupply > _totalSupply) {
            _mint(address(this), newTotalSupply - _totalSupply);
        } else {
            _burn(address(this), _totalSupply - newTotalSupply);
        }
        emit Rebase(newTotalSupply);
    }

    function updateFeeRate(uint256 newFeeRate) external onlyOwner {
        feeRate = newFeeRate;
        emit FeeRateUpdated(newFeeRate);
    }

    function updatePriceFeed(address newPriceFeed) external onlyOwner {
        priceFeed = IPriceFeed(newPriceFeed);
        emit PriceFeedUpdated(newPriceFeed);
    }

    function adjustTargetPrice(uint256 newTargetPrice) external onlyOwner {
        TARGET_PRICE = newTargetPrice;
        emit TargetPriceAdjusted(newTargetPrice);
    }

    function setEmergencyShutdown(bool _shutdown) external onlyOwner {
        emergencyShutdown = _shutdown;
        emit EmergencyShutdownSet(_shutdown);
    }

    function recoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(this), "Cannot recover KUSD tokens");
        IERC20(token).transfer(owner, amount);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

