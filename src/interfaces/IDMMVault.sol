// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DMM Vault
 * @notice Manages token reserves for Dynamic Market Maker recentering operations
 * @dev Holds DRI and USDC reserves to support band recentering without external dependencies
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IDMMVault {
    function drawTokens(address token, uint256 amount) external returns (bool);
    function depositTokens(address token, uint256 amount) external;
    function getAvailableBalance(address token) external view returns (uint256);
    function getReserveRatio(address token) external view returns (uint256);
}

contract DMMVault is IDMMVault, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Supported tokens for vault operations
    mapping(address => bool) public supportedTokens;

    /// @notice Token balances held in vault
    mapping(address => uint256) public tokenBalances;

    /// @notice Initial token deposits (used for reserve ratio calculations)
    mapping(address => uint256) public initialDeposits;

    /// @notice Authorized contracts that can draw tokens
    mapping(address => bool) public authorizedDrawers;

    /// @notice Minimum reserve ratios (in basis points)
    mapping(address => uint256) public minimumReserveRatios;

    /// @notice Total tokens ever deposited (for historical tracking)
    mapping(address => uint256) public totalDeposited;

    /// @notice Total tokens ever withdrawn (for historical tracking)
    mapping(address => uint256) public totalWithdrawn;

    /// @notice Emergency withdrawal address (governance)
    address public emergencyWithdrawer;

    /// @notice Fee collector for vault operations
    address public feeCollector;

    /// @notice Draw fee in basis points (charged on token draws)
    uint256 public drawFee = 10; // 0.1% default

    /// @notice Maximum single draw amount (in basis points of total balance)
    uint256 public maxSingleDrawBps = 2000; // 20% of balance max

    /// @notice Daily draw limit (in basis points of total balance)
    uint256 public dailyDrawLimitBps = 5000; // 50% of balance per day

    /// @notice Track daily draws for rate limiting
    mapping(address => mapping(uint256 => uint256)) public dailyDrawAmounts; // token => day => amount

    event TokenDeposited(address indexed token, uint256 amount, address indexed depositor);
    event TokenDrawn(address indexed token, uint256 amount, address indexed drawer, uint256 fee);
    event AuthorizedDrawerAdded(address indexed drawer);
    event AuthorizedDrawerRemoved(address indexed drawer);
    event TokenSupported(address indexed token, uint256 minReserveRatio);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed recipient);
    event ReserveRatioWarning(address indexed token, uint256 currentRatio, uint256 minimumRatio);

    modifier onlyAuthorizedDrawer() {
        require(authorizedDrawers[msg.sender], "Not authorized to draw tokens");
        _;
    }

    modifier onlyEmergencyWithdrawer() {
        require(msg.sender == emergencyWithdrawer || msg.sender == owner(), "Not authorized for emergency withdraw");
        _;
    }

    modifier supportedToken(address token) {
        require(supportedTokens[token], "Token not supported");
        _;
    }

    constructor(address _owner) Ownable(_owner) {
        emergencyWithdrawer = _owner;
        feeCollector = _owner;
    }

    /**
     * @notice Add support for a new token
     * @param token Token address to support
     * @param minReserveRatio Minimum reserve ratio in basis points
     */
    function addSupportedToken(address token, uint256 minReserveRatio) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(minReserveRatio <= 9500, "Reserve ratio too high"); // Max 95%
        require(minReserveRatio >= 100, "Reserve ratio too low"); // Min 1%

        supportedTokens[token] = true;
        minimumReserveRatios[token] = minReserveRatio;

        emit TokenSupported(token, minReserveRatio);
    }

    /**
     * @notice Authorize a contract to draw tokens
     * @param drawer Address to authorize (typically DMM contract)
     */
    function addAuthorizedDrawer(address drawer) external onlyOwner {
        require(drawer != address(0), "Invalid drawer address");
        authorizedDrawers[drawer] = true;
        emit AuthorizedDrawerAdded(drawer);
    }

    /**
     * @notice Remove authorization for a drawer
     * @param drawer Address to remove authorization from
     */
    function removeAuthorizedDrawer(address drawer) external onlyOwner {
        authorizedDrawers[drawer] = false;
        emit AuthorizedDrawerRemoved(drawer);
    }

    /**
     * @notice Deposit tokens into the vault
     * @param token Token address to deposit
     * @param amount Amount to deposit
     */
    function depositTokens(address token, uint256 amount) external nonReentrant supportedToken(token) {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer tokens from sender
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update balances
        tokenBalances[token] += amount;
        totalDeposited[token] += amount;

        // Set initial deposit if this is first deposit
        if (initialDeposits[token] == 0) {
            initialDeposits[token] = amount;
        }

        emit TokenDeposited(token, amount, msg.sender);
    }

    /**
     * @notice Draw tokens from the vault (only authorized drawers)
     * @param token Token address to draw
     * @param amount Amount to draw
     * @return success Whether the draw was successful
     */
    function drawTokens(address token, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyAuthorizedDrawer
        supportedToken(token)
        returns (bool success)
    {
        require(amount > 0, "Amount must be greater than 0");

        // Check available balance
        uint256 available = getAvailableBalance(token);
        require(available >= amount, "Insufficient vault balance");

        // Check single draw limit
        uint256 maxSingleDraw = (tokenBalances[token] * maxSingleDrawBps) / 10000;
        require(amount <= maxSingleDraw, "Exceeds single draw limit");

        // Check daily draw limit
        uint256 today = block.timestamp / 1 days;
        uint256 dailyDrawn = dailyDrawAmounts[token][today];
        uint256 dailyLimit = (tokenBalances[token] * dailyDrawLimitBps) / 10000;
        require(dailyDrawn + amount <= dailyLimit, "Exceeds daily draw limit");

        // Calculate fee
        uint256 fee = (amount * drawFee) / 10000;
        uint256 netAmount = amount - fee;

        // Update balances
        tokenBalances[token] -= amount;
        totalWithdrawn[token] += amount;
        dailyDrawAmounts[token][today] += amount;

        // Transfer tokens
        IERC20(token).safeTransfer(msg.sender, netAmount);

        // Transfer fee to collector
        if (fee > 0 && feeCollector != address(0)) {
            IERC20(token).safeTransfer(feeCollector, fee);
        }

        // Check reserve ratio and emit warning if needed
        uint256 currentRatio = getReserveRatio(token);
        uint256 minRatio = minimumReserveRatios[token];
        if (currentRatio < minRatio) {
            emit ReserveRatioWarning(token, currentRatio, minRatio);
        }

        emit TokenDrawn(token, amount, msg.sender, fee);
        return true;
    }

    /**
     * @notice Get available balance for a token (considering minimum reserves)
     * @param token Token address
     * @return Available balance
     */
    function getAvailableBalance(address token) public view returns (uint256) {
        if (!supportedTokens[token]) return 0;

        uint256 totalBalance = tokenBalances[token];
        uint256 minReserve = (initialDeposits[token] * minimumReserveRatios[token]) / 10000;

        return totalBalance > minReserve ? totalBalance - minReserve : 0;
    }

    /**
     * @notice Get reserve ratio for a token in basis points
     * @param token Token address
     * @return Reserve ratio (10000 = 100%)
     */
    function getReserveRatio(address token) public view returns (uint256) {
        if (!supportedTokens[token] || initialDeposits[token] == 0) return 0;

        return (tokenBalances[token] * 10000) / initialDeposits[token];
    }

    /**
     * @notice Get vault statistics for a token
     * @param token Token address
     * @return balance Current balance
     * @return available Available for withdrawal
     * @return deposited Total ever deposited
     * @return withdrawn Total ever withdrawn
     * @return ratio Current reserve ratio
     */
    function getVaultStats(address token) external view returns (
        uint256 balance,
        uint256 available,
        uint256 deposited,
        uint256 withdrawn,
        uint256 ratio
    ) {
        balance = tokenBalances[token];
        available = getAvailableBalance(token);
        deposited = totalDeposited[token];
        withdrawn = totalWithdrawn[token];
        ratio = getReserveRatio(token);
    }

    /**
     * @notice Emergency withdraw tokens (governance only)
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function emergencyWithdraw(address token, uint256 amount, address recipient)
        external
        onlyEmergencyWithdrawer
        supportedToken(token)
    {
        require(amount > 0, "Amount must be greater than 0");
        require(recipient != address(0), "Invalid recipient");
        require(tokenBalances[token] >= amount, "Insufficient balance");

        tokenBalances[token] -= amount;
        totalWithdrawn[token] += amount;

        IERC20(token).safeTransfer(recipient, amount);

        emit EmergencyWithdraw(token, amount, recipient);
    }

    /**
     * @notice Update draw fee (owner only)
     * @param newFee New fee in basis points
     */
    function setDrawFee(uint256 newFee) external onlyOwner {
        require(newFee <= 500, "Fee too high"); // Max 5%
        drawFee = newFee;
    }

    /**
     * @notice Update single draw limit (owner only)
     * @param newLimitBps New limit in basis points
     */
    function setMaxSingleDrawBps(uint256 newLimitBps) external onlyOwner {
        require(newLimitBps <= 5000, "Limit too high"); // Max 50%
        require(newLimitBps >= 100, "Limit too low"); // Min 1%
        maxSingleDrawBps = newLimitBps;
    }

    /**
     * @notice Update daily draw limit (owner only)
     * @param newLimitBps New limit in basis points
     */
    function setDailyDrawLimitBps(uint256 newLimitBps) external onlyOwner {
        require(newLimitBps <= 10000, "Limit too high"); // Max 100%
        require(newLimitBps >= 500, "Limit too low"); // Min 5%
        dailyDrawLimitBps = newLimitBps;
    }

    /**
     * @notice Update fee collector address
     * @param newCollector New collector address
     */
    function setFeeCollector(address newCollector) external onlyOwner {
        require(newCollector != address(0), "Invalid collector");
        feeCollector = newCollector;
    }

    /**
     * @notice Update emergency withdrawer
     * @param newWithdrawer New withdrawer address
     */
    function setEmergencyWithdrawer(address newWithdrawer) external onlyOwner {
        require(newWithdrawer != address(0), "Invalid withdrawer");
        emergencyWithdrawer = newWithdrawer;
    }

    /**
     * @notice Pause vault operations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause vault operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Update minimum reserve ratio for a token
     * @param token Token address
     * @param newRatio New ratio in basis points
     */
    function setMinimumReserveRatio(address token, uint256 newRatio) external onlyOwner supportedToken(token) {
        require(newRatio <= 9500, "Ratio too high"); // Max 95%
        require(newRatio >= 100, "Ratio too low"); // Min 1%
        minimumReserveRatios[token] = newRatio;
    }
}
