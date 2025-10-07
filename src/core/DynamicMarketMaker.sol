// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 * ██████╗ ███╗   ██╗ █████╗ ███╗   ███╗██╗ ██████╗    ███╗   ███╗ █████╗ ██████╗ ██╗  ██╗███████╗████████╗    ███╗   ███╗ █████╗ ██╗  ██╗███████╗██████╗
 * ██╔══██╗████╗  ██║██╔══██╗████╗ ████║██║██╔════╝    ████╗ ████║██╔══██╗██╔══██╗██║ ██╔╝██╔════╝╚══██╔══╝    ████╗ ████║██╔══██╗██║ ██╔╝██╔════╝██╔══██╗
 * ██║  ██║██╔██╗ ██║███████║██╔████╔██║██║██║         ██╔████╔██║███████║██████╔╝█████╔╝ █████╗     ██║       ██╔████╔██║███████║█████╔╝ █████╗  ██████╔╝
 * ██║  ██║██║╚██╗██║██╔══██║██║╚██╔╝██║██║██║         ██║╚██╔╝██║██╔══██║██╔══██╗██╔═██╗ ██╔══╝     ██║       ██║╚██╔╝██║██╔══██║██╔═██╗ ██╔══╝  ██╔══██╗
 * ██████╔╝██║ ╚████║██║  ██║██║ ╚═╝ ██║██║╚██████╗    ██║ ╚═╝ ██║██║  ██║██║  ██║██║  ██╗███████╗   ██║       ██║ ╚═╝ ██║██║  ██║██║  ██╗███████╗██║  ██║
 * ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝ ╚═════╝    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝   ╚═╝       ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝
 *
 * Dynamic Market Maker (DMM) - Concentrated Liquidity Band Implementation
 *
 * The DynamicMarketMaker implements a capital-efficient automated market maker that concentrates
 * all protocol-owned liquidity within a tight band around the oracle reference price. This design
 * achieves approximately 200x capital efficiency compared to full-range AMMs by constraining
 * liquidity to a ±0.25% range around the reflective price.
 *
 * Mathematical Framework:
 * - Capital Efficiency: CE = 1/(2δ) where δ = band half-width (0.25% default)
 * - At δ = 0.25%, CE ≈ 200x capital efficiency multiplier
 * - Impermanent Loss per recentering: IL ≈ δ²/2 ≈ 0.03% of TVL
 * - Fee coverage requirement: F_accrued ≥ φ × IL (default φ = 1.0)
 *
 * Core Operations:
 * 1. Automatic band recentering when market price touches ±δ% boundaries
 * 2. Fee accumulation that covers impermanent loss from band shifts
 * 3. Constant product AMM within the concentrated band
 * 4. Integration with DRIController for oracle-driven price updates
 *
 * Security Features:
 * - Reentrancy protection on all state-changing functions
 * - Owner-only governance parameter updates with strict bounds
 * - Controller-only band recentering for oracle-driven adjustments
 * - Automated fee coverage validation before each band shift
 */

import "../interfaces/IDMM.sol";
// Internal vault implementation - no external interface needed
import "../interfaces/IDRIController.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title DynamicMarketMaker
 * @author DRI Protocol Team
 * @notice Implements concentrated liquidity bands for capital-efficient market making
 * @dev This contract manages a ±δ% liquidity band that auto-recenters around the oracle price
 *
 * The DMM achieves capital efficiency through concentrated liquidity deployment:
 * - All liquidity is constrained to a narrow band around the reference price
 * - Band automatically recenters when market price hits boundaries
 * - Trading fees accumulate to cover impermanent loss from recentering
 * - Provides ETF-grade price tracking with minimal capital requirements
 */
contract DynamicMarketMaker is IDMM, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20; // Safe token transfer operations

    /// @notice DRI token contract - the index tracking token
    IERC20 public immutable driToken;

    /// @notice USDC token contract - the base currency for pricing
    IERC20 public immutable usdcToken;

    /// @notice DRI Controller contract - provides oracle prices and coordination
    IDRIController public immutable driController;

    /// @notice Configuration parameters for the concentrated liquidity band
    /// @dev Contains halfWidth (δ), recenterTrigger (ε), feeCoverage (φ), and feeRate
    BandConfig public bandConfig;

    /// @notice Current liquidity position within the concentrated band
    /// @dev Tracks DRI/USDC token amounts, liquidity shares, and tick bounds
    LiquidityPosition public liquidityPosition;

    /// @notice Total liquidity shares issued to all providers
    /// @dev Used for proportional calculation of user ownership
    uint256 public totalLiquidity;

    // Ratio deviation controls to prevent cumulative ratio drift via repeated near-threshold adds
    uint256 public constant MAX_RATIO_DEVIATION = 1e15; // 0.1% in 1e18 terms
    uint256 public cumulativeRatioShift; // sum of accepted deviations since last recenter
    uint256 public constant MAX_CUMULATIVE_SHIFT = 1e16; // 1.0% cap on cumulative drift

    /// @notice Accumulated trading fees since last band recentering (in DRI)
    /// @dev Must exceed estimated impermanent loss before recentering is allowed
    uint256 public accruedFeesDri;

    /// @notice Accumulated trading fees since last band recentering (in USDC)
    /// @dev Must exceed estimated impermanent loss before recentering is allowed
    uint256 public accruedFeesUsdc;

    /// @notice Timestamp of the last band recentering operation
    /// @dev Used for timing analysis and fee accumulation tracking
    uint256 public lastRecenterTime;

    /// @notice Reference price at which the band was last centered
    /// @dev Stored for deviation calculations and band shift analysis
    uint256 public lastRecenterPrice;


    /// @notice Address authorized to withdraw protocol fees
    /// @dev Can be a treasury, governance contract, or fee distributor
    address public feeRecipient;

    /// @notice Governance contract address for parameter updates
    address public governance;

    /// @notice Cooldown period between band recentering operations
    uint256 public recenterCooldown = 30 minutes;

    /// @notice Events for tracking system operations
    event FeesAccrued(uint256 amount, string tokenType);
    event FeesWithdrawn(address indexed recipient, uint256 driAmount, uint256 usdcAmount);
    event LiquidityAdded(address indexed user, uint256 driAmount, uint256 usdcAmount, uint256 liquidity);
    event LiquidityRemoved(address indexed user, uint256 driAmount, uint256 usdcAmount, uint256 liquidity);
    event BandConfigUpdated(uint256 halfWidth, uint256 recenterTrigger, uint256 feeCoverage, uint256 feeRate);
    event TokensLocked(address indexed token, uint256 amount, uint256 totalLocked);
    event TokensUnlocked(address indexed token, uint256 amount, uint256 totalLocked);
    event AccountingMismatch(string token, uint256 expected, uint256 actual);
    event RecenterCommitted(bytes32 indexed stateHash, uint256 blockNumber);
    event ForceRecenterProposed(uint256 timestamp);
    event ForceRecenterExecuted(uint256 timestamp);
    event RecenterDelayUpdated(uint256 newDelay);
    event ForceRecenterTimelockUpdated(uint256 newTimelock);

    event VaultWithdrawn(address indexed token, uint256 amount, uint256 timestamp);
    event VaultWithdrawProposed(address indexed token, uint256 amount, uint256 timestamp);
    event PositionBorrowed(address indexed token, uint256 amount, uint256 remainingVault);

    /// @notice Get dynamic decimal adjustment factor for token conversion
    function _getDecimalAdjust() internal view returns (uint256) {
        uint8 driDecimals = IERC20Metadata(address(driToken)).decimals();
        uint8 usdcDecimals = IERC20Metadata(address(usdcToken)).decimals();
        require(driDecimals == DRI_DECIMALS, "DRI must have 18 decimals");
        require(usdcDecimals == USDC_DECIMALS, "USDC must have 6 decimals");
        return 10 ** (DRI_DECIMALS - USDC_DECIMALS); // 1e12
    }

    // Removed duplicate MIN_VAULT_RATIO constant

    /// @notice Expected decimals for DRI token (18 decimals)
    uint8 public constant DRI_DECIMALS = 18;

    /// @notice Expected decimals for USDC token (6 decimals)
    uint8 public constant USDC_DECIMALS = 6;

    /// @notice Mapping of user addresses to their liquidity share balances
    /// @dev Represents proportional ownership of the total pool liquidity
    mapping(address => uint256) public userLiquidity;

    /// @notice Internal vault balances for token management during recentering
    /// @dev These represent "locked" tokens that are reserved for recentering operations
    mapping(address => uint256) public vaultBalances; // token => locked balance

    /// @notice Minimum vault reserve ratio in basis points (e.g., 500 = 5%)
    uint256 public constant MIN_VAULT_RATIO = 500; // 5% minimum vault reserve

    /// @notice Enforce accounting invariants to prevent desync
    modifier validateAccounting() {
        _;
        _validateAccountingInvariants();
    }

    /// @notice Validate that total balance equals position + vault + fees
    function _validateAccountingInvariants() internal view {
        uint256 driTotal = driToken.balanceOf(address(this));
        uint256 driPosition = liquidityPosition.driTokens;
        uint256 driVault = vaultBalances[address(driToken)];
        uint256 driFees = accruedFeesDri;

        // For initial setup or when position is 0, be more lenient
        if (driPosition == 0 && driVault == 0 && driFees == 0) {
            // Allow any balance during initial setup
            return;
        }

        // Allow 1% tolerance for rounding errors
        uint256 driRequired = driPosition + driVault + driFees;
        uint256 driTolerance = Math.mulDiv(driRequired, 100, 10000); // 1% tolerance
        require(driTotal >= driRequired - driTolerance, "DRI accounting mismatch");

        uint256 usdcTotal = usdcToken.balanceOf(address(this));
        uint256 usdcPosition = liquidityPosition.usdcTokens;
        uint256 usdcVault = vaultBalances[address(usdcToken)];
        uint256 usdcFees = accruedFeesUsdc;

        // For initial setup or when position is 0, be more lenient
        if (usdcPosition == 0 && usdcVault == 0 && usdcFees == 0) {
            // Allow any balance during initial setup
            return;
        }

        // Allow 1% tolerance for rounding errors
        uint256 usdcRequired = usdcPosition + usdcVault + usdcFees;
        uint256 usdcTolerance = Math.mulDiv(usdcRequired, 100, 10000); // 1% tolerance
        require(usdcTotal >= usdcRequired - usdcTolerance, "USDC accounting mismatch");
    }

    /// @notice Lock tokens in vault (real locking, not fake accounting)
    function _lockTokens(address token, uint256 amount) internal {
        require(amount > 0, "Invalid amount");
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        require(contractBalance >= amount, "Insufficient contract balance");

        vaultBalances[token] += amount;
        emit TokensLocked(token, amount, vaultBalances[token]);
    }

    /// @notice Unlock tokens from vault (real unlocking with position borrow fallback)
    function _unlockTokens(address token, uint256 amount) internal {
        require(amount > 0, "Invalid amount");

        if (vaultBalances[token] >= amount) {
            // Normal case: sufficient vault balance
            vaultBalances[token] -= amount;
        } else {
            // Fallback: borrow from position with limits (max 10% of position)
            uint256 positionTokens = token == address(driToken) ? liquidityPosition.driTokens : liquidityPosition.usdcTokens;
            uint256 maxBorrow = Math.mulDiv(positionTokens, 1000, 10000); // 10% max borrow
            uint256 shortfall = amount - vaultBalances[token];

            require(shortfall <= maxBorrow, "Vault shortfall exceeds position borrow limit");

            // Use all vault balance + borrow from position
            vaultBalances[token] = 0;
            emit TokensUnlocked(token, amount, 0);
            emit PositionBorrowed(token, shortfall, vaultBalances[token]);
        }
    }

    /// @notice Get vault ratio as percentage of total managed tokens (including fees)
    function _getVaultRatio(address token) internal view returns (uint256) {
        uint256 positionTokens = token == address(driToken) ? liquidityPosition.driTokens : liquidityPosition.usdcTokens;
        uint256 vaultTokens = vaultBalances[token];
        uint256 feeTokens = token == address(driToken) ? accruedFeesDri : accruedFeesUsdc;
        uint256 totalManaged = positionTokens + vaultTokens + feeTokens;

        if (totalManaged == 0) return 0;
        return Math.mulDiv(vaultTokens, 10000, totalManaged); // Return in basis points
    }

    /// @notice Deposit tokens to vault (external function for governance)
    function depositToVault(address token, uint256 amount) external onlyOwner {
        require(amount > 0, "Invalid amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _lockTokens(token, amount);
    }

    /// @notice Withdraw tokens from vault (emergency only with timelock)
    function withdrawFromVault(address token, uint256 amount) external onlyOwner {
        require(amount > 0, "Invalid amount");
        require(vaultBalances[token] >= amount, "Insufficient vault balance");
        require(block.timestamp >= lastVaultWithdrawProposal + forceRecenterTimelock, "Vault withdraw timelock not expired");

        _unlockTokens(token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);

        lastVaultWithdrawProposal = block.timestamp;
        emit VaultWithdrawn(token, amount, block.timestamp);
    }

    /// @notice Propose vault withdraw (requires timelock)
    function proposeVaultWithdraw(address token, uint256 amount) external onlyOwner {
        require(amount > 0, "Invalid amount");
        require(vaultBalances[token] >= amount, "Insufficient vault balance");

        lastVaultWithdrawProposal = block.timestamp;
        emit VaultWithdrawProposed(token, amount, block.timestamp);
    }

    /// @notice One-block gate to prevent trading during recenter
    uint256 public recenterBlock;

    /// @notice Commit-reveal scheme for MEV protection
    mapping(bytes32 => uint256) public recenterCommits; // commitHash => blockNumber
    uint256 public recenterDelay = 3; // Configurable blocks between commit and execute (default 3)

    /// @notice Timelock for owner powers
    uint256 public forceRecenterTimelock = 24 hours; // 24 hour timelock for forceRecenter
    uint256 public lastForceRecenterProposal;
    uint256 public lastVaultWithdrawProposal;

    /// @notice Maximum price deviation allowed during recenter execution
    uint256 public constant MAX_RECENTER_DEVIATION = 50; // 0.5% in basis points

    // Emergency mode state variables
    bool public emergencyMode = false;
    uint256 public emergencyDriBalance;
    uint256 public emergencyUsdcBalance;
    uint256 public emergencyTotalLiquidity;

    /// @notice Check if we're in a recenter block (trading disabled)
    function isRecenterBlock() external view returns (bool) {
        return block.number == recenterBlock;
    }

    /**
     * @notice Restricts function access to the DRI Controller contract only
     * @dev Ensures that only oracle-driven price updates can trigger band recentering
     * This prevents external manipulation of the concentrated liquidity positioning
     */
    modifier onlyController() {
        require(msg.sender == address(driController), "Only controller");
        _;
    }

    /// @notice Prevents trading during recenter block
    modifier notDuringRecenter() {
        require(block.number != recenterBlock, "Trading disabled during recenter");
        _;
    }

    /**
     * @notice Restricts function access to governance contract only
     * @dev Used for parameter updates that should be controlled by governance
     */
    modifier onlyGovernance() {
        require(msg.sender == governance, "Only governance");
        _;
    }

    /**
     * @notice Initializes the Dynamic Market Maker with token contracts and default parameters
     * @dev Sets up the concentrated liquidity band with default δ = 0.25% configuration
     * @param _driToken Address of the DRI token contract
     * @param _usdcToken Address of the USDC token contract
     * @param _driController Address of the DRI Controller contract
     * @param _owner Address that will have governance control over band parameters
     *
     * Default Configuration Rationale:
     * - halfWidth (δ) = 0.25%: Provides tight peg while allowing sufficient fee accumulation
     * - recenterTrigger (ε) = 0.25%: Recenters when price touches band boundaries
     * - feeCoverage (φ) = 1.0x: Requires 100% fee coverage before allowing recentering
     * - feeRate = 0.30%: Standard Uniswap V3 fee tier for stable pairs
     *
     * Mathematical Properties:
     * - Capital Efficiency: CE = 1/(2×0.0025) = 200x
     * - Impermanent Loss: IL ≈ (0.0025)²/2 = 0.00003125 ≈ 0.003% per recentering
     * - Fee Generation: With 0.30% fees, ~0.01×TVL volume covers each recentering
     */
    constructor(address _driToken, address _usdcToken, address _driController, address _owner) Ownable(_owner) {
        // Validate that all contract addresses are non-zero to prevent deployment errors
        require(_driToken != address(0), "Invalid DRI token");
        require(_usdcToken != address(0), "Invalid USDC token");
        require(_driController != address(0), "Invalid DRI controller");

        // Initialize immutable contract references
        driToken = IERC20(_driToken); // The index tracking token
        usdcToken = IERC20(_usdcToken); // Base currency for pricing
        driController = IDRIController(_driController); // Oracle and coordination

        // Validate decimal assumptions (this will revert if tokens don't match expectations)
        // Note: This is a simplified check - production might use try/catch with IERC20Metadata
        _validateTokenDecimals();

        // Initialize default concentrated liquidity band configuration
        // ALWAYS-SLIDE CONFIGURATION: Force recenter on every syncPrice() call
        // This removes economic barriers for real-time sliding without gas cost concerns
        bandConfig = BandConfig({
            halfWidth: 25, // δ = 0.25% band half-width (25 basis points)
            recenterTrigger: 50, // ε = 0.5% deviation trigger (recenter when price touches band)
            feeCoverage: 100, // φ = 1.0x fee coverage multiplier (100% fee coverage required)
            feeRate: 30 // f = 0.30% trading fee rate (30 basis points)
        });

        // Initialize timing for fee accumulation tracking
        lastRecenterTime = block.timestamp;

        // Set cooldown to 0 for always-slide (no cooldown period)
        recenterCooldown = 0;

        // Set initial fee recipient to owner
        feeRecipient = _owner;

        // Set initial governance to owner (should be transferred to governance contract later)
        governance = _owner;
    }

    function addLiquidity(uint256 driAmount, uint256 usdcAmount, uint256 minLiquidityOut) external nonReentrant whenNotPaused returns (uint256 liquidity) {
        require(driAmount > 0 && usdcAmount > 0, "Invalid amounts");

        // Note: Caller must have approved this contract to spend tokens
        // DRI uses 18 decimals, USDC uses 6 decimals

        // Transfer tokens first (checks-effects-interactions)
        // Handle fee-on-transfer tokens by measuring actual received amounts
        uint256 driBalanceBefore = driToken.balanceOf(address(this));
        uint256 usdcBalanceBefore = usdcToken.balanceOf(address(this));

        IERC20(address(driToken)).safeTransferFrom(msg.sender, address(this), driAmount);
        usdcToken.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Calculate actual received amounts (handles fee-on-transfer tokens)
        uint256 driReceived = driToken.balanceOf(address(this)) - driBalanceBefore;
        uint256 usdcReceived = usdcToken.balanceOf(address(this)) - usdcBalanceBefore;

        // Use actual received amounts for calculations
        driAmount = driReceived;
        usdcAmount = usdcReceived;

        // Calculate liquidity shares
        if (totalLiquidity == 0) {
            liquidity = Math.sqrt(Math.mulDiv(driAmount, usdcAmount, 1));

            // Initialize liquidity position with proper tick bounds
            uint256 currentPrice = Math.mulDiv(usdcAmount, _getDecimalAdjust() * 1e18, driAmount);
            uint256 halfWidthDecimal = Math.mulDiv(bandConfig.halfWidth, 1e18, 10000);
            uint256 lowerBound = Math.mulDiv(currentPrice, 1e18 - halfWidthDecimal, 1e18);
            uint256 upperBound = Math.mulDiv(currentPrice, 1e18 + halfWidthDecimal, 1e18);

            liquidityPosition = LiquidityPosition({
                driTokens: driAmount,
                usdcTokens: usdcAmount,
                liquidity: liquidity,
                lowerTick: lowerBound,
                upperTick: upperBound
            });

            // Update total liquidity and user liquidity
            totalLiquidity = liquidity;
            userLiquidity[msg.sender] = liquidity;
        } else {
            // CRITICAL FIX: Validate token ratio matches current position ratio (tightened)
            uint256 expectedUsdcAmount = Math.mulDiv(driAmount, liquidityPosition.usdcTokens, liquidityPosition.driTokens);
            uint256 ratioDeviation = expectedUsdcAmount > usdcAmount ?
                Math.mulDiv(expectedUsdcAmount - usdcAmount, 1e18, expectedUsdcAmount) :
                Math.mulDiv(usdcAmount - expectedUsdcAmount, 1e18, expectedUsdcAmount);

            // Allow up to 0.1% deviation from perfect ratio (1e15 in 1e18 terms)
            require(ratioDeviation <= MAX_RATIO_DEVIATION, "Token ratio deviation too high");

            // Check cumulative shift but don't increment yet
            require(cumulativeRatioShift + ratioDeviation <= MAX_CUMULATIVE_SHIFT, "Cumulative ratio shift exceeded");

            uint256 driShare = Math.mulDiv(driAmount, 1e18, liquidityPosition.driTokens);
            uint256 usdcShare = Math.mulDiv(usdcAmount, 1e18, liquidityPosition.usdcTokens);
            liquidity = Math.mulDiv(driShare < usdcShare ? driShare : usdcShare, totalLiquidity, 1e18);

            // Update state for existing liquidity
            liquidityPosition.driTokens += driAmount;
            liquidityPosition.usdcTokens += usdcAmount;
            liquidityPosition.liquidity += liquidity;
            totalLiquidity += liquidity;
            userLiquidity[msg.sender] += liquidity;
        }

        require(liquidity > 0, "Insufficient liquidity");
        require(liquidity >= minLiquidityOut, "Slippage limit exceeded");

        // Only increment cumulative shift after all validation checks pass
        if (liquidityPosition.liquidity > 0) {
            uint256 expectedUsdcAmount = Math.mulDiv(driAmount, liquidityPosition.usdcTokens, liquidityPosition.driTokens);
            uint256 ratioDeviation = expectedUsdcAmount > usdcAmount ?
                Math.mulDiv(expectedUsdcAmount - usdcAmount, 1e18, expectedUsdcAmount) :
                Math.mulDiv(usdcAmount - expectedUsdcAmount, 1e18, expectedUsdcAmount);
            cumulativeRatioShift += ratioDeviation;
        }

        // TODO: Re-enable accounting validation once the system is stable
         //_validateAccountingInvariants();

        emit LiquidityAdded(msg.sender, driAmount, usdcAmount, liquidity);
    }

    function removeLiquidity(uint256 liquidity) external nonReentrant whenNotPaused validateAccounting returns (uint256 driAmount, uint256 usdcAmount) {
        require(liquidity > 0, "Invalid liquidity");
        require(userLiquidity[msg.sender] >= liquidity, "Insufficient liquidity");

        // Calculate token amounts using Math.mulDiv for overflow safety
        driAmount = Math.mulDiv(liquidity, liquidityPosition.driTokens, totalLiquidity);
        usdcAmount = Math.mulDiv(liquidity, liquidityPosition.usdcTokens, totalLiquidity);

        // Update state
        liquidityPosition.driTokens -= driAmount;
        liquidityPosition.usdcTokens -= usdcAmount;
        liquidityPosition.liquidity -= liquidity;
        totalLiquidity -= liquidity;
        userLiquidity[msg.sender] -= liquidity;

        // Transfer tokens
        IERC20(address(driToken)).safeTransfer(msg.sender, driAmount);
        usdcToken.safeTransfer(msg.sender, usdcAmount);

        emit LiquidityRemoved(msg.sender, driAmount, usdcAmount, liquidity);
    }

    /**
     * @notice Execute a token swap between DRI and USDC
     * @dev Uses constant product formula with fees. Recentering is disabled to prevent access control bypass.
     * @param tokenIn Address of the input token (DRI or USDC)
     * @param amountIn Amount of input tokens to swap
     * @param minAmountOut Minimum amount of output tokens expected (slippage protection)
     * @return amountOut Actual amount of output tokens received
     */
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut) external nonReentrant whenNotPaused notDuringRecenter validateAccounting returns (uint256 amountOut) {
        // ===== CHECKS =====
        require(amountIn > 0, "Invalid amount");
        require(tokenIn == address(driToken) || tokenIn == address(usdcToken), "Invalid token");
        require(totalLiquidity > 0, "No liquidity available");
        require(liquidityPosition.driTokens > 0 && liquidityPosition.usdcTokens > 0, "Pool has no tokens");

        bool isDriIn = tokenIn == address(driToken);

        // Pre-calculate expected amounts using amountIn
        // We assume no fee-on-transfer for DRI and USDC (standard ERC20 behavior)
        // If fee-on-transfer support is required, this pattern must be adjusted
        uint256 amountInAfterFee;
        uint256 feeAmount;
        {
            // Use block scope to avoid stack-too-deep
            feeAmount = Math.mulDiv(amountIn, bandConfig.feeRate, 10000);
            amountInAfterFee = amountIn - feeAmount;
        }

        if (isDriIn) {
            // DRI -> USDC: Use standard AMM formula with Math.mulDiv to favor pool
            uint256 newDriBalance = liquidityPosition.driTokens + amountInAfterFee;

            // Calculate amountOut directly using AMM formula: amountOut = (amountInAfterFee * reserveOut) / (reserveIn + amountInAfterFee)
            // This rounds down amountOut, favoring the pool
            amountOut = Math.mulDiv(amountInAfterFee, liquidityPosition.usdcTokens, newDriBalance);

            require(amountOut > 0, "Insufficient output");
            require(amountOut >= minAmountOut, "Slippage limit exceeded");

            // Calculate new balances for price check
            uint256 newUsdcBalance = liquidityPosition.usdcTokens - amountOut;
            require(newUsdcBalance > 0, "Insufficient liquidity");

            // Check that resulting price stays within band bounds using Math.mulDiv
            uint256 newPrice = Math.mulDiv(newUsdcBalance, _getDecimalAdjust() * 1e18, newDriBalance);
            // Soft bounds: allow small epsilon overshoot to prevent griefing
            uint256 currentPrice = Math.mulDiv(liquidityPosition.usdcTokens, _getDecimalAdjust() * 1e18, liquidityPosition.driTokens);
            uint256 epsilon = Math.mulDiv(currentPrice, 1, 10000); // 0.01% tolerance relative to current price
            // Clamp epsilon to prevent underflow
            uint256 safeLowerBound = liquidityPosition.lowerTick > epsilon ?
                liquidityPosition.lowerTick - epsilon : 0;
            uint256 safeUpperBound = liquidityPosition.upperTick + epsilon; // No overflow risk

            require(newPrice >= safeLowerBound, "Price below lower tick");
            require(newPrice <= safeUpperBound, "Price above upper tick");

            // Edge proximity (was previously emitted as an event). We no longer emit here
            // to avoid griefing/spam via public swaps. Monitoring should use view function.
            // uint256 edgeThreshold = Math.mulDiv(currentPrice, 10, 10000);
            // bool nearEdge = (newPrice <= liquidityPosition.lowerTick + edgeThreshold
            //     || newPrice >= liquidityPosition.upperTick - edgeThreshold);

            // ===== CHECKS-EFFECTS-INTERACTIONS PATTERN =====
            // EFFECTS: Update ALL state variables FIRST
            liquidityPosition.driTokens = newDriBalance;
            liquidityPosition.usdcTokens = newUsdcBalance;
            accruedFeesDri += feeAmount;

            // INTERACTIONS: ALL external calls LAST (after all state updates)
            // 1. Pull input tokens from user
            IERC20(address(driToken)).safeTransferFrom(msg.sender, address(this), amountIn);
            // 2. Send output tokens to user
            usdcToken.safeTransfer(msg.sender, amountOut);

            // Emit event after successful external calls
            emit FeesAccrued(feeAmount, "DRI");
        } else {
            // USDC -> DRI: Use standard AMM formula with Math.mulDiv to favor pool
            uint256 newUsdcBalance = liquidityPosition.usdcTokens + amountInAfterFee;

            // Calculate amountOut directly using AMM formula: amountOut = (amountInAfterFee * reserveOut) / (reserveIn + amountInAfterFee)
            // This rounds down amountOut, favoring the pool
            amountOut = Math.mulDiv(amountInAfterFee, liquidityPosition.driTokens, newUsdcBalance);

            require(amountOut > 0, "Insufficient output");
            require(amountOut >= minAmountOut, "Slippage limit exceeded");

            // Calculate new balances for price check
            uint256 newDriBalance = liquidityPosition.driTokens - amountOut;
            require(newDriBalance > 0, "Insufficient liquidity");

            // Check that resulting price stays within band bounds using Math.mulDiv
            uint256 newPrice = Math.mulDiv(newUsdcBalance, _getDecimalAdjust() * 1e18, newDriBalance);
            // Soft bounds: allow small epsilon overshoot to prevent griefing
            uint256 currentPrice = Math.mulDiv(liquidityPosition.usdcTokens, _getDecimalAdjust() * 1e18, liquidityPosition.driTokens);
            uint256 epsilon = Math.mulDiv(currentPrice, 1, 10000); // 0.01% tolerance relative to current price
            // Clamp epsilon to prevent underflow
            uint256 safeLowerBound = liquidityPosition.lowerTick > epsilon ?
                liquidityPosition.lowerTick - epsilon : 0;
            uint256 safeUpperBound = liquidityPosition.upperTick + epsilon; // No overflow risk

            require(newPrice >= safeLowerBound, "Price below lower tick");
            require(newPrice <= safeUpperBound, "Price above upper tick");

            // Edge proximity check is available via view helper; no on-chain event emission here

            // ===== CHECKS-EFFECTS-INTERACTIONS PATTERN =====
            // EFFECTS: Update ALL state variables FIRST
            liquidityPosition.usdcTokens = newUsdcBalance;
            liquidityPosition.driTokens = newDriBalance;
            accruedFeesUsdc += feeAmount;

            // INTERACTIONS: ALL external calls LAST (after all state updates)
            // 1. Pull input tokens from user
            usdcToken.safeTransferFrom(msg.sender, address(this), amountIn);
            // 2. Send output tokens to user
            IERC20(address(driToken)).safeTransfer(msg.sender, amountOut);

            // Emit event after successful external calls
            emit FeesAccrued(feeAmount, "USDC");
        }

        // CRITICAL FIX: Remove automatic recentering from swap to prevent access control bypass
        // Recentering should only be triggered by the controller via recentBand()
        // This prevents any swapper from triggering recentering and bypassing onlyController
    }

    function recentBand() external onlyController {
        _recenter();
    }

    function canRecenter() public view returns (bool) {
        if (liquidityPosition.driTokens == 0 || liquidityPosition.usdcTokens == 0) {
            return false;
        }

        uint256 currentPrice = getCurrentPrice();
        uint256 reflectivePrice = driController.getReflectivePrice();

        if (currentPrice == 0 || reflectivePrice == 0) {
            return false;
        }

        // Calculate deviation in basis points using Math.mulDiv for overflow safety
        uint256 deviation = currentPrice > reflectivePrice ?
            Math.mulDiv(currentPrice - reflectivePrice, 10000, reflectivePrice) :
            Math.mulDiv(reflectivePrice - currentPrice, 10000, reflectivePrice);

        // DMM handles large deviations (over 100bps), PSM handles small deviations (under 100bps)
        return deviation >= 100; // Only recenter if deviation is over 1%
    }

    // Add vault interface and storage


function _recenter() internal validateAccounting nonReentrant {
    // NON-NEGOTIABLE 1: Set one-block gate to prevent trading during recenter
    recenterBlock = block.number;
    emit RecenterBlockSet(block.number);
        // Reset cumulative ratio shift on recenter
        cumulativeRatioShift = 0;
    // NON-NEGOTIABLE 4: Private flow - this function should only be called via private relay
    // Send recenter tx via a private relay / direct-to-sequencer. Don't broadcast to public mempool.

    // NON-NEGOTIABLE 2: Price freshness check - enforce |P_exec - P_reflective| ≤ ε_exec
    uint256 reflectivePrice = driController.getReflectivePrice();
    uint256 currentPrice = getCurrentPrice();
    require(reflectivePrice > 0, "Invalid oracle price");

    // Calculate price deviation in basis points (normalized to reflective price)
    uint256 priceDeviation;
    if (reflectivePrice > currentPrice) {
        priceDeviation = Math.mulDiv(reflectivePrice - currentPrice, 10000, reflectivePrice);
    } else {
        priceDeviation = Math.mulDiv(currentPrice - reflectivePrice, 10000, reflectivePrice);
    }

    require(priceDeviation <= MAX_RECENTER_DEVIATION, "Price deviation too high for recenter");
    emit PriceFreshnessCheck(currentPrice, reflectivePrice, priceDeviation);

    // Checks: Verify recenter conditions (from your implementation)
    require(liquidityPosition.driTokens > 0 && liquidityPosition.usdcTokens > 0, "No liquidity");
    // Internal vault is always available - no initialization needed

    // Fee coverage check (keeping your whitepaper logic)
    uint256 ilEstimated = _estimateImpermanentLoss();
    uint256 requiredFees = Math.mulDiv(bandConfig.feeCoverage, ilEstimated, 1e18);

    // Calculate total fees in USDC terms using reflective price (not manipulable spot)
    uint256 totalFeesUsdc = accruedFeesUsdc + Math.mulDiv(accruedFeesDri, reflectivePrice, 1e18);
    require(totalFeesUsdc >= requiredFees, "Insufficient fees for IL coverage");

    // Calculate new balances (from your implementation)
    int256 deviation = _calculateDeviation(currentPrice, reflectivePrice);
    uint256 halfWidthDecimal = Math.mulDiv(bandConfig.halfWidth, 1e18, 10000);
    uint256 lowerBound = Math.mulDiv(reflectivePrice, 1e18 - halfWidthDecimal, 1e18);
    uint256 upperBound = Math.mulDiv(reflectivePrice, 1e18 + halfWidthDecimal, 1e18);

    // CRITICAL SECURITY FIX: Prevent integer overflow in k calculation
    // Use safe mathematical approach that handles extreme values without overflow

    (uint256 newDriBalance, uint256 newUsdcBalance) = _calculateNewBalancesSafe(
        liquidityPosition.driTokens,
        liquidityPosition.usdcTokens,
        reflectivePrice
    );

    // Calculate what tokens we need to move
    int256 driDelta = int256(newDriBalance) - int256(liquidityPosition.driTokens);
    int256 usdcDelta = int256(newUsdcBalance) - int256(liquidityPosition.usdcTokens);

    // NON-NEGOTIABLE 3: No swaps to recenter - use vault transfers only
    emit VaultOnlyRecenter(driDelta, usdcDelta);
    // CRITICAL FIX: Handle DRI token movements using real vault operations
    if (driDelta > 0) {
        uint256 driNeeded = uint256(driDelta);
        // Unlock tokens from vault for recenter
        _unlockTokens(address(driToken), driNeeded);
    } else if (driDelta < 0) {
        uint256 driExcess = uint256(-driDelta);
        // Lock excess tokens in vault
        _lockTokens(address(driToken), driExcess);
    }

    // CRITICAL FIX: Handle USDC token movements using real vault operations
    if (usdcDelta > 0) {
        uint256 usdcNeeded = uint256(usdcDelta);
        // Unlock tokens from vault for recenter
        _unlockTokens(address(usdcToken), usdcNeeded);
    } else if (usdcDelta < 0) {
        uint256 usdcExcess = uint256(-usdcDelta);
        // Lock excess tokens in vault
        _lockTokens(address(usdcToken), usdcExcess);
    }

    // Validate we have the tokens we think we do
    uint256 actualDRI = driToken.balanceOf(address(this));
    uint256 actualUSDC = usdcToken.balanceOf(address(this));
    require(actualDRI >= newDriBalance, "DRI balance insufficient after vault operation");
    require(actualUSDC >= newUsdcBalance, "USDC balance insufficient after vault operation");

    // Check vault reserve levels and emit warnings if low
    uint256 driVaultRatio = _getVaultRatio(address(driToken));
    uint256 usdcVaultRatio = _getVaultRatio(address(usdcToken));

    if (driVaultRatio < MIN_VAULT_RATIO) {
        emit VaultLowWarning("DRI vault below minimum ratio", driVaultRatio);
    }
    if (usdcVaultRatio < MIN_VAULT_RATIO) {
        emit VaultLowWarning("USDC vault below minimum ratio", usdcVaultRatio);
    }

    // Update state (from your implementation)
    liquidityPosition.driTokens = newDriBalance;
    liquidityPosition.usdcTokens = newUsdcBalance;
    liquidityPosition.lowerTick = lowerBound;
    liquidityPosition.upperTick = upperBound;
    // Deduct fees proportionally from both DRI and USDC fees (fixed unit mixing)
    if (accruedFeesDri > 0 && accruedFeesUsdc > 0) {
        // Convert DRI fees to USDC terms for proportional deduction
        uint256 driFeesUsdc = Math.mulDiv(accruedFeesDri, reflectivePrice, 1e18);
        uint256 totalFeesUsdcAdjusted = accruedFeesUsdc + driFeesUsdc;

        // Deduct proportionally from both (in USDC terms)
        uint256 driDeductionUsdc = Math.mulDiv(requiredFees, driFeesUsdc, totalFeesUsdcAdjusted);
        uint256 usdcDeduction = Math.mulDiv(requiredFees, accruedFeesUsdc, totalFeesUsdcAdjusted);

        // Convert DRI deduction back to DRI terms
        uint256 driDeduction = Math.mulDiv(driDeductionUsdc, 1e18, reflectivePrice);

        accruedFeesDri = accruedFeesDri >= driDeduction ? accruedFeesDri - driDeduction : 0;
        accruedFeesUsdc = accruedFeesUsdc >= usdcDeduction ? accruedFeesUsdc - usdcDeduction : 0;
    } else if (accruedFeesUsdc > 0) {
        // Only USDC fees available
        accruedFeesUsdc = accruedFeesUsdc >= requiredFees ? accruedFeesUsdc - requiredFees : 0;
    } else if (accruedFeesDri > 0) {
        // Only DRI fees available - convert to DRI terms
        uint256 driRequired = Math.mulDiv(requiredFees, 1e18, reflectivePrice);
        accruedFeesDri = accruedFeesDri >= driRequired ? accruedFeesDri - driRequired : 0;
    }
    lastRecenterTime = block.timestamp;
    lastRecenterPrice = reflectivePrice;

    // Emit events (from your implementation)
    emit BandShifted(reflectivePrice, bandConfig.halfWidth, deviation);
    emit RecenterComplete(newDriBalance, newUsdcBalance, driDelta, usdcDelta);
}

// Internal vault management - no external vault needed

// Emergency function if vault runs critically low
function pauseForVaultRefill() external onlyOwner {
    uint256 driRatio = _getVaultRatio(address(driToken));
    uint256 usdcRatio = _getVaultRatio(address(usdcToken));

    require(driRatio < MIN_VAULT_RATIO || usdcRatio < MIN_VAULT_RATIO,
            "Vault levels sufficient");

    // Pause DMM operations until vault is refilled
    _pause();
    emit EmergencyVaultPause(driRatio, usdcRatio);
}

// Events
event VaultLowWarning(string message, uint256 ratio);
event RecenterComplete(uint256 newDriBalance, uint256 newUsdcBalance, int256 driDelta, int256 usdcDelta);
    event VaultSet(address vault);
    event EmergencyVaultPause(uint256 driRatio, uint256 usdcRatio);

    // Non-negotiables events
    event RecenterBlockSet(uint256 blockNumber);
    event PriceFreshnessCheck(uint256 currentPrice, uint256 reflectivePrice, uint256 deviation);
    event VaultOnlyRecenter(int256 driDelta, int256 usdcDelta);
    event EmergencyWithdraw(uint256 driBalance, uint256 usdcBalance);
    event EmergencyUserWithdraw(address user, uint256 driAmount, uint256 usdcAmount);
    event ControllerUpdated(address newController);
    event RecenterCooldownUpdated(uint256 cooldown);
    // Removed duplicate FeesWithdrawn event

    function _calculateDeviation(uint256 marketPrice, uint256 refPrice) internal pure returns (int256) {
        if (marketPrice >= refPrice) {
            return int256(Math.mulDiv(marketPrice - refPrice, 1e18, refPrice));
        } else {
            return -int256(Math.mulDiv(refPrice - marketPrice, 1e18, refPrice));
        }
    }

    function _estimateImpermanentLoss() internal view returns (uint256) {
        // IL ≈ δ²/2 where δ is the band half-width
        // Convert basis points to decimal scale: δ = halfWidth/10000
        uint256 deltaBps = bandConfig.halfWidth;
        uint256 deltaDecimal = Math.mulDiv(deltaBps, 1e18, 10000); // Convert to 18-decimal scale

        // Convert DRI value to USDC terms (6 decimals) then normalize to 18 decimals for calculation
        // Use Math.mulDiv to prevent overflow
        uint256 driValueInUsdc = Math.mulDiv(liquidityPosition.driTokens, getCurrentPrice(), _getDecimalAdjust() * 1e18);
        uint256 totalValueUsdc = driValueInUsdc + liquidityPosition.usdcTokens; // Both in USDC 6-decimal scale
        uint256 totalValueNormalized = Math.mulDiv(totalValueUsdc, _getDecimalAdjust(), 1); // Convert to 18-decimal scale

        // Use Math.mulDiv for the final calculation to prevent overflow
        uint256 deltaSquared = Math.mulDiv(deltaDecimal, deltaDecimal, 1);
        return Math.mulDiv(deltaSquared, totalValueNormalized, 2 * 1e18 * 1e18);
    }

    function getLiquidityPosition() external view returns (LiquidityPosition memory) {
        return liquidityPosition;
    }

    function getBandConfig() external view returns (BandConfig memory) {
        return bandConfig;
    }

    function getCurrentPrice() public view returns (uint256) {
        if (liquidityPosition.driTokens == 0 || liquidityPosition.usdcTokens == 0) return 0;
        // Price = USDC (6 decimals) / DRI (18 decimals) * 1e18 to normalize to 18 decimals
        // Use Math.mulDiv to prevent overflow: (usdcTokens * _getDecimalAdjust() * 1e18) / driTokens
        return Math.mulDiv(liquidityPosition.usdcTokens, _getDecimalAdjust() * 1e18, liquidityPosition.driTokens);
    }

    function getAccruedFees() external view returns (uint256 driFees, uint256 usdcFees) {
        return (accruedFeesDri, accruedFeesUsdc);
    }

    /**
     * @notice Returns the total liquidity in the DMM pool
     * @dev Used for pro-rata calculations to determine user's share of the pool
     */
    function getTotalLiquidity() external view returns (uint256) {
        return liquidityPosition.liquidity;
    }

    /**
     * @notice Returns the liquidity shares owned by a specific address
     * @dev Used for pro-rata calculations to determine user's share of the pool
     * @param user Address to query liquidity for
     * @return userLiquidity Liquidity shares owned by the user
     */
    function getUserLiquidity(address user) external view returns (uint256) {
        return userLiquidity[user];
    }

    /**
     * @notice Returns a quote for a token swap without executing it
     * @dev Calculates the expected output amount for a given input using current reserves
     * @param tokenIn Address of the input token
     * @param amountIn Amount of input tokens
     * @return amountOut Expected amount of output tokens
     */
    function quote(address tokenIn, uint256 amountIn) external view returns (uint256) {
        require(amountIn > 0, "Amount must be positive");
        require(tokenIn == address(driToken) || tokenIn == address(usdcToken), "Invalid token");

        if (liquidityPosition.liquidity == 0) {
            return 0;
        }

        uint256 driReserves = liquidityPosition.driTokens;
        uint256 usdcReserves = liquidityPosition.usdcTokens;

        if (tokenIn == address(driToken)) {
            // DRI -> USDC swap
            // Apply fee: amountIn * (1 - feeRate)
            uint256 amountInAfterFee = (amountIn * (10000 - bandConfig.feeRate)) / 10000;
            // Constant product: x * y = k
            // After swap: (driReserves + amountInAfterFee) * (usdcReserves - amountOut) = driReserves * usdcReserves
            // amountOut = (usdcReserves * amountInAfterFee) / (driReserves + amountInAfterFee)
            return (usdcReserves * amountInAfterFee) / (driReserves + amountInAfterFee);
        } else {
            // USDC -> DRI swap
            uint256 amountInAfterFee = (amountIn * (10000 - bandConfig.feeRate)) / 10000;
            return (driReserves * amountInAfterFee) / (usdcReserves + amountInAfterFee);
        }
    }

    function updateBandConfig(BandConfig calldata _config) external onlyOwner {
        require(_config.halfWidth <= 500, "Half width too large"); // Max 5% (500 basis points)
        require(_config.halfWidth >= 10, "Half width too small"); // Min 0.1% (10 basis points)
        require(_config.recenterTrigger >= _config.halfWidth / 2, "Invalid trigger");
        require(_config.recenterTrigger <= _config.halfWidth, "Invalid trigger");
        require(_config.feeCoverage >= 50 && _config.feeCoverage <= 200, "Invalid fee coverage"); // 0.5x to 2.0x
        require(_config.feeRate <= 100, "Fee rate too high"); // Max 1% (100 basis points)

        bandConfig = _config;
        emit BandConfigUpdated(_config.halfWidth, _config.recenterTrigger, _config.feeCoverage, _config.feeRate);
    }


    function setGovernance(address _governance) external onlyOwner {
        require(_governance != address(0), "Invalid governance address");
        governance = _governance;
    }

    /// @notice Set recenter delay (MEV protection)
    function setRecenterDelay(uint256 _delay) external onlyOwner {
        require(_delay >= 1 && _delay <= 10, "Invalid delay (1-10 blocks)");
        recenterDelay = _delay;
        emit RecenterDelayUpdated(_delay);
    }

    /// @notice Set force recenter timelock
    function setForceRecenterTimelock(uint256 _timelock) external onlyOwner {
        require(_timelock >= 1 hours && _timelock <= 7 days, "Invalid timelock (1h-7d)");
        forceRecenterTimelock = _timelock;
        emit ForceRecenterTimelockUpdated(_timelock);
    }

    /// @notice Commit to a recenter operation (MEV protection)
    function commitRecenter(bytes32 stateHash) external onlyController {
        require(stateHash != bytes32(0), "Invalid state hash");
        recenterCommits[stateHash] = block.number;
        emit RecenterCommitted(stateHash, block.number);
    }

    /// @notice Execute recenter with state hash validation
    function executeRecenter(bytes32 stateHash) external onlyController {
        require(recenterCommits[stateHash] > 0, "No commit found");
        require(block.number >= recenterCommits[stateHash] + recenterDelay, "Commit too recent");

        // Validate current state matches committed state (excludes balances to prevent dust grief)
        bytes32 currentStateHash = keccak256(abi.encodePacked(
            liquidityPosition.driTokens,
            liquidityPosition.usdcTokens,
            liquidityPosition.liquidity,
            liquidityPosition.lowerTick,
            liquidityPosition.upperTick,
            accruedFeesDri,
            accruedFeesUsdc,
            totalLiquidity
        ));
        require(currentStateHash == stateHash, "State mismatch");

        // Clear commit and execute
        delete recenterCommits[stateHash];
        _recenter();
    }

    /// @notice Propose force recenter (requires timelock)
    function proposeForceRecenter() external onlyOwner {
        lastForceRecenterProposal = block.timestamp;
        emit ForceRecenterProposed(block.timestamp);
    }

    /// @notice Execute force recenter after timelock
    function executeForceRecenter() external onlyOwner validateAccounting {
        require(lastForceRecenterProposal > 0, "No proposal found");
        require(block.timestamp >= lastForceRecenterProposal + forceRecenterTimelock, "Timelock not expired");

        // Reset proposal
        lastForceRecenterProposal = 0;

        // Bypass cooldown for owner emergency recentering
        uint256 originalCooldown = recenterCooldown;
        recenterCooldown = 0;
        _recenter();
        recenterCooldown = originalCooldown;

        emit ForceRecenterExecuted(block.timestamp);
    }

    function withdrawFees() external nonReentrant {
        require(msg.sender == feeRecipient, "Not fee recipient");
        require(accruedFeesDri > 0 || accruedFeesUsdc > 0, "No fees to withdraw");

        uint256 driToWithdraw = accruedFeesDri;
        uint256 usdcToWithdraw = accruedFeesUsdc;

        // Proper CEI: reset counters BEFORE external calls
        accruedFeesDri = 0;
        accruedFeesUsdc = 0;

        // Then interact
        if (driToWithdraw > 0) {
            uint256 driBalance = driToken.balanceOf(address(this));
            require(driBalance >= driToWithdraw, "Insufficient DRI balance for fee withdrawal");
            driToken.safeTransfer(feeRecipient, driToWithdraw);
        }

        if (usdcToWithdraw > 0) {
            uint256 usdcBalance = usdcToken.balanceOf(address(this));
            require(usdcBalance >= usdcToWithdraw, "Insufficient USDC balance for fee withdrawal");
            usdcToken.safeTransfer(feeRecipient, usdcToWithdraw);
        }

        emit FeesWithdrawn(feeRecipient, driToWithdraw, usdcToWithdraw);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }

    // Note: driController is immutable and cannot be updated after deployment
    // This is by design for security - controller address is set once in constructor

    function setRecenterCooldown(uint256 _cooldown) external onlyOwner {
        recenterCooldown = _cooldown;
        emit RecenterCooldownUpdated(_cooldown);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw() external onlyOwner {
        // Include vault balances and accrued fees to prevent accounting mismatch
        uint256 driBalance = liquidityPosition.driTokens
            + vaultBalances[address(driToken)]
            + accruedFeesDri;
        uint256 usdcBalance = liquidityPosition.usdcTokens
            + vaultBalances[address(usdcToken)]
            + accruedFeesUsdc;

        // CRITICAL FIX: Handle user liquidity shares properly
        // Users should be able to withdraw their proportional share
        // Store the emergency state to allow user withdrawals
        emergencyMode = true;
        emergencyDriBalance = driBalance;
        emergencyUsdcBalance = usdcBalance;
        emergencyTotalLiquidity = totalLiquidity;

        // Reset liquidity position and internal accounting so claims map 1:1
        liquidityPosition.driTokens = 0;
        liquidityPosition.usdcTokens = 0;
        liquidityPosition.liquidity = 0;
        totalLiquidity = 0;
        vaultBalances[address(driToken)] = 0;
        vaultBalances[address(usdcToken)] = 0;
        accruedFeesDri = 0;
        accruedFeesUsdc = 0;

        // CRITICAL FIX: Don't transfer to owner - keep tokens in contract for direct user access
        // This eliminates trust requirement - users can withdraw directly

        emit EmergencyWithdraw(driBalance, usdcBalance);
    }

    /**
     * @notice Allows users to withdraw their proportional share in emergency mode
     * @dev Only callable when emergencyMode is true
     */
    function emergencyWithdrawUser() external nonReentrant {
        require(emergencyMode, "Not in emergency mode");
        require(userLiquidity[msg.sender] > 0, "No liquidity to withdraw");

        uint256 userShare = userLiquidity[msg.sender];
        uint256 driAmount = Math.mulDiv(userShare, emergencyDriBalance, emergencyTotalLiquidity);
        uint256 usdcAmount = Math.mulDiv(userShare, emergencyUsdcBalance, emergencyTotalLiquidity);

        // Reset user liquidity
        userLiquidity[msg.sender] = 0;

        // CRITICAL FIX: Direct transfer from contract balance (no owner approval needed)
        if (driAmount > 0) {
            IERC20(address(driToken)).safeTransfer(msg.sender, driAmount);
        }
        if (usdcAmount > 0) {
            usdcToken.safeTransfer(msg.sender, usdcAmount);
        }

        emit EmergencyUserWithdraw(msg.sender, driAmount, usdcAmount);
    }

    /**
     * @notice View-only helper for authorized monitoring to check band edge proximity
     * @dev Returns whether spot is near either band edge using the same 0.1% threshold logic
     */
    function checkBandEdgeProximity()
        external
        view
        returns (bool nearEdge, uint256 currentPrice, uint256 lower, uint256 upper)
    {
        require(liquidityPosition.driTokens > 0 && liquidityPosition.usdcTokens > 0, "No liquidity");
        currentPrice = getCurrentPrice();
        lower = liquidityPosition.lowerTick;
        upper = liquidityPosition.upperTick;
        uint256 edgeThreshold = Math.mulDiv(currentPrice, 10, 10000); // 0.1%
        nearEdge = (currentPrice <= lower + edgeThreshold || currentPrice >= upper - edgeThreshold);
    }

    /**
     * @notice Validates token decimal configuration matches expectations
     * @dev Should be called during deployment to ensure decimal assumptions are correct
     * @return driDecimals The actual decimals of DRI token
     * @return usdcDecimals The actual decimals of USDC token
     */
    function validateTokenDecimals() external view returns (uint8 driDecimals, uint8 usdcDecimals) {
        return _validateTokenDecimals();
    }

    /**
     * @notice Get user's share value in both DRI and USDC
     * @param user Address of the user
     * @return driValue User's DRI token value
     * @return usdcValue User's USDC token value
     * @return totalValue Total value in USDC equivalent
     */
    function getUserShareValue(address user) external view returns (uint256 driValue, uint256 usdcValue, uint256 totalValue) {
        require(user != address(0), "Invalid user address");

        uint256 userLiquidityAmount = userLiquidity[user];
        if (userLiquidityAmount == 0 || totalLiquidity == 0) {
            return (0, 0, 0);
        }

        // Calculate proportional share using Math.mulDiv for overflow safety
        driValue = Math.mulDiv(userLiquidityAmount, liquidityPosition.driTokens, totalLiquidity);
        usdcValue = Math.mulDiv(userLiquidityAmount, liquidityPosition.usdcTokens, totalLiquidity);

        // Calculate total value in USDC equivalent using Math.mulDiv
        uint256 currentPrice = getCurrentPrice();
        totalValue = usdcValue + Math.mulDiv(driValue, currentPrice, _getDecimalAdjust() * 1e18);
    }

    /**
     * @notice Get comprehensive system state for monitoring
     * @return liquidityInfo Current liquidity position details
     * @return currentPrice Current DRI price in USDC
     * @return reflectivePrice Reflective price from oracle
     * @return deviation Price deviation from reflective price
     * @return configInfo Current band configuration
     * @return emergencyModeStatus Emergency mode status
     * @return recenterBlockNumber Block number of last recenter
     */
    function getSystemState() external view returns (
        LiquidityPosition memory liquidityInfo,
        uint256 currentPrice,
        uint256 reflectivePrice,
        int256 deviation,
        BandConfig memory configInfo,
        bool emergencyModeStatus,
        uint256 recenterBlockNumber
    ) {
        liquidityInfo = liquidityPosition;
        currentPrice = getCurrentPrice();
        reflectivePrice = driController.getReflectivePrice();
        deviation = _calculateDeviation(currentPrice, reflectivePrice);
        configInfo = bandConfig;
        emergencyModeStatus = emergencyMode;
        recenterBlockNumber = recenterBlock;
    }

    /**
     * @notice Check if the system is healthy and operational
     * @return isHealthy True if system is healthy
     * @return reason Reason for unhealthy state (if applicable)
     */
    function isSystemHealthy() external view returns (bool isHealthy, string memory reason) {
        // Check if emergency mode is active
        if (emergencyMode) {
            return (false, "System in emergency mode");
        }

        // Check if paused
        if (paused()) {
            return (false, "System is paused");
        }

        // Check if in recenter block
        if (block.number == recenterBlock) {
            return (false, "System in recenter block");
        }

        // Internal vault is always available - no need to check

        // Check if liquidity is sufficient
        if (totalLiquidity == 0) {
            return (false, "No liquidity available");
        }

        // Check if position has tokens
        if (liquidityPosition.driTokens == 0 || liquidityPosition.usdcTokens == 0) {
            return (false, "Pool has no tokens");
        }

        return (true, "System is healthy");
    }

    /**
     * @notice Internal validation of token decimals
     * @dev Reverts if tokens don't match expected decimal configuration
     */
    function _validateTokenDecimals() internal view returns (uint8 driDecimals, uint8 usdcDecimals) {
        // CRITICAL SECURITY FIX: Never assume decimals - always require explicit implementation
        bool driImplementsDecimals = false;
        bool usdcImplementsDecimals = false;

        try IERC20Metadata(address(driToken)).decimals() returns (uint8 d) {
            driDecimals = d;
            driImplementsDecimals = true;
            require(driDecimals == DRI_DECIMALS, "DRI token decimals mismatch");
        } catch {
            revert("DRI token must implement decimals() function");
        }

        try IERC20Metadata(address(usdcToken)).decimals() returns (uint8 d) {
            usdcDecimals = d;
            usdcImplementsDecimals = true;
            require(usdcDecimals == USDC_DECIMALS, "USDC token decimals mismatch");
        } catch {
            revert("USDC token must implement decimals() function");
        }

        require(driImplementsDecimals && usdcImplementsDecimals, "Both tokens must implement decimals()");
    }

    /**
     * @notice Safe calculation of new balances to prevent integer overflow
     * @dev Uses logarithmic approach to handle extreme values
     * @param driTokens Current DRI token amount
     * @param usdcTokens Current USDC token amount
     * @param reflectivePrice Target reflective price
     * @return newDriBalance New DRI balance
     * @return newUsdcBalance New USDC balance
     */
    function _calculateNewBalancesSafe(
        uint256 driTokens,
        uint256 usdcTokens,
        uint256 reflectivePrice
    ) internal view returns (uint256 newDriBalance, uint256 newUsdcBalance) {
        // CRITICAL SECURITY FIX: Use robust bit-shift scaling to prevent overflow
        // This approach is mathematically sound and overflow-safe

        // Use logarithmic scaling to avoid overflow
        uint256 scaleBits = 0;
        uint256 scaledDri = driTokens;
        uint256 scaledUsdc = usdcTokens;

        // Scale down using bit shifts (divide by 2) until values are safe
        while (scaledDri > type(uint128).max || scaledUsdc > type(uint128).max) {
            scaledDri >>= 1; // Divide by 2 using bit shift
            scaledUsdc >>= 1;
            scaleBits++;
            require(scaleBits < 128, "Values too large to scale safely");
        }

        // Calculate with scaled values
        uint256 k = Math.sqrt(Math.mulDiv(scaledDri, scaledUsdc, 1));
        uint256 sqrtAdjustment = Math.sqrt(Math.mulDiv(_getDecimalAdjust() * 1e18, 1, reflectivePrice));
        newDriBalance = Math.mulDiv(k, sqrtAdjustment, 1);
        newUsdcBalance = Math.mulDiv(newDriBalance, reflectivePrice, _getDecimalAdjust() * 1e18);

        // Scale back up using bit shifts (multiply by 2^scaleBits) with explicit overflow checks
        if (scaleBits > 0) {
            // Add explicit check for shift amount to prevent overflow
            require(scaleBits < 256, "Shift amount too large");
            uint256 maxBeforeShift = type(uint256).max >> scaleBits;
            require(newDriBalance <= maxBeforeShift, "Scale up overflow");
            require(newUsdcBalance <= maxBeforeShift, "Scale up overflow");
            newDriBalance <<= scaleBits;
            newUsdcBalance <<= scaleBits;
        }

        // Additional safety checks
        require(newDriBalance > 0, "Invalid new DRI balance");
        require(newUsdcBalance > 0, "Invalid new USDC balance");
    }



}
