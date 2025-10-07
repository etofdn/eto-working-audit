// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDRIController
 * @author DRI Protocol Team
 * @notice Interface for the central DRI Controller that manages reflective price updates and system coordination
 * @dev The DRIController is the heart of the Dynamic Reflective Index protocol. It coordinates all major
 *      system components including oracle aggregation, reflective price calculations, circuit breakers,
 *      and integration with the Dynamic Market Maker (DMM) and Peg Stability Module (PSM).
 *
 * Core Responsibilities:
 * 1. Reflective Price Management - Updates the internal price parameter that tracks the external index
 * 2. Circuit Breaker Coordination - Monitors deviations and triggers protective mechanisms
 * 3. System Integration - Coordinates between DMM band recentering and PSM interventions
 * 4. Deviation Monitoring - Tracks market vs. reflective price divergence for automated responses
 *
 * Mathematical Foundation:
 * The reflective price update mechanism uses capped multiplicative adjustments:
 *
 * Raw Factor: α_raw = P_twap / R_t-1
 * Capped Factor: α = clamp(α_raw, 1-Δ, 1+Δ) where Δ = max adjustment per tick
 * New Reflective Price: R_t = R_t-1 × α
 *
 * This ensures controlled convergence toward the true index price while preventing
 * manipulation through extreme price movements.
 */
interface IDRIController {
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // EVENTS - All major system events for transparency and monitoring
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when the reflective price is updated via syncPrice()
     * @dev This is the core event that tracks how the DRI's internal price parameter evolves
     *      over time. External systems can monitor this to understand price tracking behavior.
     *
     * @param newPrice The updated reflective price after applying capped adjustment
     * @param timestamp Block timestamp when the update occurred
     */
    event ReflectivePriceUpdated(uint256 newPrice, uint256 timestamp);

    /**
     * @notice Emitted during each deviation check between market and reflective price
     * @dev Used for monitoring and analytics to track how closely the market price follows
     *      the reflective price. High deviations may trigger DMM recentering or PSM intervention.
     *
     * @param timestamp When the deviation check was performed
     * @param marketPrice Current market price from the DMM pool
     * @param reflectivePrice Current internal reflective price
     * @param deviation Signed deviation: (marketPrice - reflectivePrice) / reflectivePrice * 10000 (basis points)
     * @param maxDeviation Current maximum allowed deviation before triggering interventions
     */
    event DeviationCheck(
        uint256 timestamp, uint256 marketPrice, uint256 reflectivePrice, int256 deviation, uint256 maxDeviation
    );

    /**
     * @notice Emitted when deviation exceeds warning thresholds but hasn't triggered intervention yet
     * @dev Early warning system for monitoring tools and governance to track potential issues
     *      before they require automated intervention. Helps with proactive monitoring.
     *
     * @param timestamp When the warning was triggered
     * @param deviation The deviation level that triggered the warning (in basis points)
     */
    event DeviationWarning(uint256 timestamp, uint256 deviation);

    /**
     * @notice Emitted when the DMM's concentrated liquidity band is recentered
     * @dev The DMM automatically recenters its ±δ% liquidity band when the market price
     *      deviates too far from the reflective price. This event tracks these recentering operations.
     *
     * @param newReflectivePrice The reflective price around which the band was recentered
     * @param bandHalfWidth The half-width of the band (δ) in basis points (e.g., 25 = 0.25%)
     * @param deviation The deviation that triggered the recentering
     */
    event BandShifted(uint256 newReflectivePrice, uint256 bandHalfWidth, int256 deviation);

    /**
     * @notice Emitted when a PSM (Peg Stability Module) swap is needed but not yet executed
     * @dev Indicates that the deviation has exceeded the DMM's ability to handle and PSM
     *      intervention is required. This creates transparency about when reserve funds are being used.
     *
     * @param deviation The deviation level that triggered the pending PSM swap
     */
    event PSMSwapPending(uint256 deviation);

    /**
     * @notice Emitted when the PSM executes a peg-stabilizing swap
     * @dev Records all PSM interventions for transparency and audit trails. These swaps use
     *      protocol reserves to buy or sell DRI tokens to restore the peg when market forces alone are insufficient.
     *
     * @param isBuy True if PSM bought DRI (market price below reflective), false if sold DRI
     * @param amount Amount of tokens involved in the swap
     * @param newPrice Market price after the PSM intervention
     */
    event PSMSwap(bool isBuy, uint256 amount, uint256 newPrice);

    /**
     * @notice Emitted when the Controller directly executes PSM arbitrage
     * @dev Records automatic PSM execution triggered by the Controller during price sync operations.
     *
     * @param isBuy True if PSM bought DRI (market price below reflective), false if sold DRI
     * @param swapSize Amount of tokens involved in the swap
     * @param amountOut Amount of tokens received from the swap
     */
    event PSMExecuted(bool isBuy, uint256 swapSize, uint256 amountOut);

    /**
     * @notice Emitted when a circuit breaker is triggered due to extreme conditions
     * @dev Circuit breakers provide emergency protection against various failure modes:
     *      Level 1 (Warning): Increased monitoring, no operational changes
     *      Level 2 (Throttle): Reduced adjustment caps, slower rebalancing
     *      Level 3 (Halt): Complete suspension of automated peg maintenance
     *
     * @param level The circuit breaker level that was triggered (1=Warning, 2=Throttle, 3=Halt)
     * @param deviation The deviation level that triggered the circuit breaker
     */
    event CircuitBreakerTriggered(uint8 level, uint256 deviation);

    /**
     * @notice Emitted when circuit breakers are released and normal operation resumes
     * @dev Indicates that extreme conditions have subsided and the protocol has returned
     *      to normal automated operation. Important for monitoring system health.
     */
    event CircuitBreakerReleased();

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════
    // CORE FUNCTIONS - Primary system operations
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Updates the reflective price based on current oracle data
     * @dev This is the core function that implements the reflective price update mechanism.
     *      It should be called regularly (every 15-30 seconds) to keep the DRI tracking the external index.
     *
     * Process Flow:
     * 1. Fetch aggregated price from oracle system (P_twap)
     * 2. Calculate raw adjustment factor: α_raw = P_twap / R_t-1
     * 3. Apply adjustment cap: α = clamp(α_raw, 1-Δ, 1+Δ)
     * 4. Update reflective price: R_t = R_t-1 × α
     * 5. Check for needed DMM recentering or PSM intervention
     * 6. Trigger circuit breakers if deviation exceeds thresholds
     *
     * The function uses capped adjustments to prevent manipulation while ensuring
     * gradual convergence toward the true index price over time.
     *
     * Requirements:
     * - Oracle system MUST be providing valid, non-stale data
     * - Circuit breakers MUST NOT be in halt mode
     * - Caller should have appropriate role (may be permissionless in some implementations)
     *
     * Side Effects:
     * - May trigger DMM band recentering if market price deviates beyond band width
     * - May trigger PSM intervention if deviation exceeds PSM threshold
     * - May activate circuit breakers if extreme conditions are detected
     * - Updates internal price history for TWAP calculations
     */
    function syncPrice() external;

    /**
     * @notice Returns the current reflective price (internal tracking price)
     * @dev This is the protocol's internal price parameter that tracks the external index.
     *      It's updated through the capped reflective price mechanism and serves as the
     *      reference point for all DMM and PSM operations.
     *
     * The reflective price is always:
     * - Scaled to 18 decimals for consistent internal calculations
     * - Updated gradually through capped adjustments (max Δ% per tick)
     * - Used as the center point for DMM liquidity bands
     * - The reference for calculating deviations and triggering interventions
     *
     * @return reflectivePrice Current internal reflective price scaled to 18 decimals
     */
    function getReflectivePrice() external view returns (uint256 reflectivePrice);

    /**
     * @notice Returns the current market price from the DMM liquidity pool
     * @dev Calculates the instantaneous market price based on the DMM's token reserves.
     *      This represents what traders are actually paying/receiving for DRI tokens
     *      and is compared against the reflective price to measure tracking accuracy.
     *
     * Calculation: Market Price = USDC_reserves / DRI_reserves
     *
     * The market price can deviate from reflective price due to:
     * - Trading activity and temporary supply/demand imbalances
     * - Lag in reflective price updates (15-30 second intervals)
     * - Market sentiment and speculation
     * - External arbitrage opportunities
     *
     * @return marketPrice Current market price from DMM pool scaled to 18 decimals
     */
    function getMarketPrice() external view returns (uint256 marketPrice);

    /**
     * @notice Calculates the current deviation between market and reflective price
     * @dev Returns the signed percentage deviation in basis points (10000 = 100%).
     *      This is the key metric used to trigger all automated interventions.
     *
     * Calculation: deviation = (marketPrice - reflectivePrice) / reflectivePrice × 10000
     *
     * Interpretation:
     * - Positive deviation: Market price above reflective (potential sell pressure)
     * - Negative deviation: Market price below reflective (potential buy pressure)
     * - Zero deviation: Perfect tracking (rare in practice)
     *
     * Thresholds (typical values):
     * - ±25 basis points: DMM band recentering trigger
     * - ±50 basis points: PSM intervention threshold
     * - ±200 basis points: Circuit breaker activation
     *
     * @return deviation Signed deviation in basis points (positive = market above reflective)
     */
    function getDeviation() external view returns (int256 deviation);

    /**
     * @notice Checks if any circuit breaker is currently active and returns the level
     * @dev Circuit breakers provide graduated emergency protection against various failure modes.
     *      Each level has different operational implications and recovery conditions.
     *
     * Circuit Breaker Levels:
     * - Level 0: Normal operation, no restrictions
     * - Level 1: Warning mode, increased monitoring but no operational changes
     * - Level 2: Throttle mode, reduced adjustment caps and slower rebalancing
     * - Level 3: Halt mode, complete suspension of automated peg maintenance
     *
     * Recovery typically requires sustained return to normal conditions or governance intervention.
     *
     * @return isActive True if any circuit breaker level is currently engaged
     * @return level The current circuit breaker level (0=None, 1=Warning, 2=Throttle, 3=Halt)
     */
    function isCircuitBreakerActive() external view returns (bool isActive, uint8 level);
}
