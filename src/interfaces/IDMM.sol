// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDMM
 * @author DRI Protocol Team
 * @notice Interface for the Dynamic Market Maker (DMM) with Concentrated Liquidity Bands
 * @dev The DMM implements capital-efficient automated market making using concentrated liquidity
 *      positioned within tight bands around the reflective price. This achieves ~200x capital
 *      efficiency compared to full-range AMMs while maintaining tight price tracking.
 *
 * Core Innovation - Concentrated Liquidity Band (CLB):
 * The DMM deploys all liquidity within a narrow ±δ% band centered on the reflective price,
 * where δ is typically 0.25%. This concentration provides massive capital efficiency:
 *
 * Capital Efficiency = 1 / (2δ) = 1 / (2 × 0.0025) = 200x
 *
 * Key Features:
 * 1. Auto-recentering when market price touches band edges
 * 2. Fee accumulation covers impermanent loss from band shifts
 * 3. Protocol-owned liquidity removes external LP dependencies
 * 4. Predictable slippage and price impact within the band
 *
 * Mathematical Foundation:
 * - Band Range: [R_t(1-δ), R_t(1+δ)] where R_t = current reflective price
 * - Recentering Trigger: |M_t - R_t| ≥ ε where ε = δ (typically)
 * - Impermanent Loss per Shift: IL ≈ δ²/2 ≈ 0.03% for δ=0.25%
 * - Fee Requirement: F_accrued ≥ φ × IL before recentering (φ=1 default)
 */
interface IDMM {
    /**
     * @notice Structure representing the current concentrated liquidity position
     * @dev Tracks the state of liquidity deployed within the active band. The DMM maintains
     *      a single active position that gets recentered as the reflective price moves.
     *
     * @param driTokens Amount of DRI tokens in the current liquidity position
     * @param usdcTokens Amount of USDC tokens in the current liquidity position
     * @param lowerTick Lower bound of the concentrated liquidity range (price tick)
     * @param upperTick Upper bound of the concentrated liquidity range (price tick)
     * @param liquidity Total liquidity shares for this position (geometric mean of token amounts)
     */
    struct LiquidityPosition {
        uint256 driTokens; // DRI token balance in active position
        uint256 usdcTokens; // USDC token balance in active position
        uint256 lowerTick; // Lower tick boundary (R_t × (1-δ))
        uint256 upperTick; // Upper tick boundary (R_t × (1+δ))
        uint256 liquidity; // Total liquidity shares (√(driTokens × usdcTokens))
    }

    /**
     * @notice Configuration parameters for the concentrated liquidity band operation
     * @dev These parameters control the DMM's behavior and can be updated through governance.
     *      They determine band width, recentering sensitivity, and fee requirements.
     *
     * @param halfWidth Band half-width δ in basis points (25 = 0.25%)
     * @param recenterTrigger Deviation threshold ε that triggers recentering (usually = halfWidth)
     * @param feeCoverage Fee coverage multiplier φ (100 = 1x, meaning fees must ≥ 1x IL before recentering)
     * @param feeRate Trading fee rate in basis points (30 = 0.30%)
     */
    struct BandConfig {
        uint256 halfWidth; // δ - Band half-width in basis points (e.g., 25 = 0.25%)
        uint256 recenterTrigger; // ε - Deviation that triggers recentering in basis points
        uint256 feeCoverage; // φ - Fee coverage multiplier (100 = 1.0x)
        uint256 feeRate; // f - Trading fee rate in basis points (30 = 0.30%)
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // EVENTS - Track all major DMM operations for transparency and monitoring
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when the concentrated liquidity band is recentered around a new reflective price
     * @dev Band recentering is the core operation that maintains price tracking. It occurs when
     *      the market price deviates beyond the band edges, requiring liquidity repositioning.
     *
     * @param newReflectivePrice The updated reflective price around which the band was centered
     * @param bandHalfWidth Current band half-width δ in basis points
     * @param deviation The price deviation that triggered the recentering
     */
    event BandShifted(uint256 newReflectivePrice, uint256 bandHalfWidth, int256 deviation);

    /**
     * @notice Emitted when liquidity is added to the DMM (protocol or external)
     * @dev Tracks all liquidity additions, whether from initial seeding, protocol additions,
     *      or external liquidity providers (if allowed by governance).
     *
     * @param driAmount DRI tokens added to the liquidity position
     * @param usdcAmount USDC tokens added to the liquidity position
     * @param liquidity Liquidity shares minted for this addition
     */
    event LiquidityAdded(uint256 driAmount, uint256 usdcAmount, uint256 liquidity);

    /**
     * @notice Emitted when liquidity is removed from the DMM
     * @dev Tracks liquidity withdrawals, important for monitoring overall pool depth
     *      and ensuring sufficient liquidity for price stability.
     *
     * @param driAmount DRI tokens removed from the liquidity position
     * @param usdcAmount USDC tokens removed from the liquidity position
     * @param liquidity Liquidity shares burned for this removal
     */
    event LiquidityRemoved(uint256 driAmount, uint256 usdcAmount, uint256 liquidity);

    /**
     * @notice Emitted when trading fees are collected from swaps
     * @dev Fee accumulation is critical for covering impermanent loss from band recentering.
     *      This event helps monitor whether sufficient fees are being generated.
     *
     * @param amount Amount of fees accrued (in USDC-equivalent value)
     */
    event FeesAccrued(uint256 amount);

    /**
     * @notice Emitted when band configuration parameters are updated via governance
     * @dev Configuration changes affect DMM behavior and should be monitored closely
     *      as they impact capital efficiency, recentering frequency, and fee coverage.
     *
     * @param newConfig Updated configuration parameters
     */
    event BandConfigUpdated(BandConfig newConfig);

    /**
     * @notice Emitted when emergency withdrawal is executed
     * @dev Emergency withdrawals are used during system shutdown or crisis situations
     *      to protect user funds by withdrawing all liquidity to the owner.
     *
     * @param owner Address that received the withdrawn tokens
     * @param driAmount DRI tokens withdrawn
     * @param usdcAmount USDC tokens withdrawn
     */
    event EmergencyWithdraw(address indexed owner, uint256 driAmount, uint256 usdcAmount);

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // LIQUIDITY MANAGEMENT - Core AMM functions for liquidity provision
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Adds liquidity to the concentrated liquidity band
     * @dev Provides tokens to the active liquidity position, receiving liquidity shares in return.
     *      The liquidity is added at the current band center (reflective price) with the configured
     *      range width. This function is typically used for initial seeding or protocol additions.
     *
     * Liquidity Calculation:
     * - If first liquidity: shares = √(driAmount × usdcAmount)
     * - Otherwise: shares = min(driRatio, usdcRatio) × totalLiquidity
     *
     * Requirements:
     * - Both token amounts must be > 0
     * - Tokens must be provided in correct ratio for current price
     * - Caller must have sufficient token balances and approvals
     * - Band must be properly initialized
     *
     * @param driAmount Amount of DRI tokens to add
     * @param usdcAmount Amount of USDC tokens to add
     * @param minLiquidityOut Minimum liquidity shares expected (slippage protection)
     * @return liquidity Amount of liquidity shares minted
     */
    function addLiquidity(uint256 driAmount, uint256 usdcAmount, uint256 minLiquidityOut) external returns (uint256 liquidity);

    /**
     * @notice Removes liquidity from the concentrated liquidity band
     * @dev Burns liquidity shares and returns proportional amounts of both tokens.
     *      The withdrawal is from the active band position at current token ratios.
     *
     * Token Calculation:
     * - driAmount = (liquidity / totalLiquidity) × totalDRITokens
     * - usdcAmount = (liquidity / totalLiquidity) × totalUSDCTokens
     *
     * Requirements:
     * - liquidity amount must be > 0 and ≤ caller's balance
     * - Sufficient tokens must be available in the position
     * - Cannot remove more than proportional share
     *
     * @param liquidity Amount of liquidity shares to burn
     * @return driAmount DRI tokens returned to caller
     * @return usdcAmount USDC tokens returned to caller
     */
    function removeLiquidity(uint256 liquidity) external returns (uint256 driAmount, uint256 usdcAmount);

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // TRADING FUNCTIONS - Swap operations within the concentrated band
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Executes a token swap within the concentrated liquidity band
     * @dev Performs constant-product AMM swap within the active band. Fees are collected
     *      on each swap and accumulate toward covering impermanent loss from recentering.
     *
     * Swap Mechanics:
     * 1. Apply trading fee (typically 0.30%)
     * 2. Calculate output using constant product formula: x × y = k
     * 3. Update token balances within the band
     * 4. Check if recentering is needed after the swap
     * 5. Accrue fees for impermanent loss coverage
     *
     * Price Impact:
     * Due to concentrated liquidity, price impact is minimized within the band but
     * increases rapidly if trades push price toward band edges.
     *
     * Requirements:
     * - tokenIn must be either DRI or USDC token address
     * - amountIn must be > 0
     * - Sufficient liquidity must exist for the trade
     * - Resulting price must remain within reasonable bounds
     *
     * @param tokenIn Address of input token (DRI or USDC)
     * @param amountIn Amount of input tokens to swap
     * @param minAmountOut Minimum amount of output tokens expected (slippage protection)
     * @return amountOut Amount of output tokens received (after fees)
     */
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut);

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // BAND MANAGEMENT - Recentering and configuration functions
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Recenters the concentrated liquidity band around the current reflective price
     * @dev This is the core function that maintains price tracking by moving the liquidity
     *      band when the market price deviates beyond configured thresholds.
     *
     * Recentering Process:
     * 1. Check deviation: |M_t - R_t| ≥ ε (recentering trigger)
     * 2. Verify fee coverage: F_accrued ≥ φ × IL_estimated
     * 3. Withdraw all liquidity from current band
     * 4. Calculate new band range: [R_t(1-δ), R_t(1+δ)]
     * 5. Re-deploy liquidity in new band centered on R_t
     * 6. Update internal state and emit events
     *
     * Economics:
     * - Impermanent Loss: IL ≈ δ²/2 per recentering
     * - Fee Coverage: Trading fees must cover IL before allowing recentering
     * - Capital Efficiency: Maintained at 1/(2δ) ≈ 200x for δ=0.25%
     *
     * Requirements:
     * - Market price deviation must exceed trigger threshold
     * - Accumulated fees must cover estimated impermanent loss
     * - Valid reflective price must be available from controller
     * - Caller must have appropriate permissions
     */
    function recentBand() external;

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS - State queries and information retrieval
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the current liquidity position details
     * @dev Provides complete information about the active concentrated liquidity position
     *      including token balances, tick range, and total liquidity shares.
     *
     * @return position Current LiquidityPosition struct with all position details
     */
    function getLiquidityPosition() external view returns (LiquidityPosition memory position);

    /**
     * @notice Returns the current band configuration parameters
     * @dev Provides all configurable parameters that control DMM behavior including
     *      band width, recentering thresholds, and fee settings.
     *
     * @return config Current BandConfig struct with all configuration parameters
     */
    function getBandConfig() external view returns (BandConfig memory config);

    /**
     * @notice Calculates the current market price based on token reserves
     * @dev Returns the instantaneous price from the AMM using the constant product formula.
     *      This price represents what traders are actually paying for DRI tokens.
     *
     * Calculation: price = usdcTokens / driTokens
     *
     * Note: This price may deviate from the reflective price due to trading activity
     * and will trigger recentering when deviation exceeds thresholds.
     *
     * @return price Current market price from AMM (USDC per DRI, scaled to 18 decimals)
     */
    function getCurrentPrice() external view returns (uint256 price);

    /**
     * @notice Returns the total amount of trading fees accrued since last recentering
     * @dev Fee accumulation is crucial for determining when recentering is economically
     *      viable. Fees must cover estimated impermanent loss before band shifts occur.
     *
     * @return driFees Total accrued DRI fees
     * @return usdcFees Total accrued USDC fees
     */
    function getAccruedFees() external view returns (uint256 driFees, uint256 usdcFees);

    /**
     * @notice Checks if the band can be recentered based on current conditions
     * @dev Evaluates both deviation and fee coverage requirements to determine if
     *      recentering is allowed. Used for automated triggering and monitoring.
     *
     * Conditions Checked:
     * 1. Deviation: |M_t - R_t| ≥ ε (recentering trigger threshold)
     * 2. Fee Coverage: F_accrued ≥ φ × IL_estimated (economic viability)
     * 3. System State: No circuit breakers active, valid oracle data available
     *
     * @return canRecenter True if all conditions for recentering are met
     */
    function canRecenter() external view returns (bool canRecenter);

    /**
     * @notice Returns the total liquidity in the DMM pool
     * @dev Used for pro-rata calculations to determine user's share of the pool
     *
     * @return totalLiquidity Total liquidity shares in the pool
     */
    function getTotalLiquidity() external view returns (uint256 totalLiquidity);

    /**
     * @notice Returns the liquidity shares owned by a specific address
     * @dev Used for pro-rata calculations to determine user's share of the pool
     *
     * @param user Address to query liquidity for
     * @return userLiquidity Liquidity shares owned by the user
     */
    function getUserLiquidity(address user) external view returns (uint256 userLiquidity);

    /**
     * @notice Returns a quote for a token swap without executing it
     * @dev Calculates the expected output amount for a given input using current reserves
     *      This is useful for slippage protection and user experience
     *
     * @param tokenIn Address of the input token
     * @param amountIn Amount of input tokens
     * @return amountOut Expected amount of output tokens
     */
    function quote(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut);
}
