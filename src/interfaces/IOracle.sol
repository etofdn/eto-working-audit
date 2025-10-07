// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOracle
 * @author DRI Protocol Team
 * @notice Interface for price oracle contracts that provide external asset pricing data
 * @dev This interface defines the standard for all oracle implementations used by the DRI protocol.
 *      Oracles must provide price data with timestamps and indicate if the data is stale.
 *      The DRI system uses multiple oracles and aggregates their data for increased reliability.
 *
 * Key Design Principles:
 * - Price data includes timestamp for age verification
 * - Staleness detection prevents using outdated prices
 * - Decimal precision support for different price feed formats
 * - Standard interface allows pluggable oracle implementations
 */
interface IOracle {
    /**
     * @notice Retrieves the latest price and timestamp from the oracle
     * @dev This function MUST return the most recent valid price data available.
     *      The price should be normalized to 18 decimals (scaled by 10^18).
     *      The timestamp should be a Unix timestamp of when the price was last updated.
     *
     * Example: If the external price feed reports $100.50 with 8 decimals as 10050000000,
     *          this function should return (100500000000000000000, 1640995200)
     *          representing $100.50 scaled to 18 decimals and timestamp.
     *
     * @return price The latest price scaled to 18 decimal places (wei-equivalent)
     * @return timestamp Unix timestamp of when this price was last updated
     *
     * Requirements:
     * - MUST NOT revert under normal conditions
     * - Price MUST be positive (> 0)
     * - Timestamp MUST be a valid Unix timestamp
     * - Price MUST be scaled to 18 decimals regardless of source precision
     */
    function getPrice() external returns (uint256 price, uint256 timestamp);

    /**
     * @notice Get price data without emitting events (for off-chain reads)
     * @dev This function is view-only and does not emit events, suitable for UI and off-chain queries
     * @return price The current price in 18 decimals
     * @return timestamp Unix timestamp of when this price was last updated
     */
    function viewPrice() external view returns (uint256 price, uint256 timestamp);

    /**
     * @notice Checks if the oracle's price data is considered stale
     * @dev Staleness is determined by comparing the last update timestamp with a predefined
     *      maximum age threshold. This prevents the use of outdated price data that could
     *      lead to incorrect reflective price calculations or exploitable arbitrage conditions.
     *
     * Implementation Note:
     * Different oracle types may have different staleness thresholds:
     * - Chainlink: Typically 1-4 hours depending on the asset
     * - High-frequency: May be 15-30 minutes
     * - Traditional finance APIs: Could be 1-24 hours
     *
     * @return isStale True if the price data is too old to be reliable, false otherwise
     *
     * Requirements:
     * - MUST return true if timestamp is older than configured threshold
     * - MUST be consistent with getPrice() timestamp
     */
    function isStale() external view returns (bool isStale);

    /**
     * @notice Returns the decimal precision of the original price data source
     * @dev This information is used for display purposes and validation, but all prices
     *      returned by getPrice() should already be normalized to 18 decimals.
     *      This helps with debugging and ensuring proper price scaling.
     *
     * Common Values:
     * - 8 decimals: Chainlink USD pairs (e.g., ETH/USD, BTC/USD)
     * - 18 decimals: Many ERC20 tokens and DeFi protocols
     * - 6 decimals: USDC and similar stablecoins
     *
     * @return decimals The number of decimal places in the source price feed
     *
     * Requirements:
     * - MUST return a value between 0 and 77 (Solidity's decimal limit)
     * - SHOULD represent the actual source decimals, not the normalized 18
     */
    function getDecimals() external view returns (uint8 decimals);
}

/**
 * @title IOracleAggregator
 * @author DRI Protocol Team
 * @notice Interface for the oracle aggregation system that combines multiple price sources
 * @dev The aggregator implements the core oracle layer functionality described in the DRI whitepaper.
 *      It manages multiple oracle sources, performs median calculation, applies TWAP smoothing,
 *      and provides outlier detection to ensure robust price discovery.
 *
 * Architecture Overview:
 * 1. Multiple independent oracles feed price data
 * 2. Median calculation eliminates extreme outliers
 * 3. Time-Weighted Average Price (TWAP) smooths short-term volatility
 * 4. Staleness detection removes unreliable sources
 * 5. Weight-based influence allows quality-based prioritization
 *
 * Mathematical Foundation:
 * - Median Price: P_median = median(P1, P2, ..., Pn) where n ≥ 3
 * - TWAP: P_twap = Σ(Pi × ti) / Σ(ti) over window W
 * - Deviation Check: |Pi - P_median| / P_median ≤ δ_max (e.g., 1%)
 */
interface IOracleAggregator {
    /**
     * @notice Data structure containing oracle configuration and state information
     * @dev Stores all essential information about each oracle in the aggregation system
     * @param oracle Address of the oracle contract implementing IOracle interface
     * @param weight Relative weight for median calculation (0-10000, where 10000 = 100%)
     * @param lastUpdate Timestamp of the last successful price update from this oracle
     * @param isActive Whether this oracle is currently active and being used for aggregation
     */
    struct OracleData {
        address oracle; // Oracle contract address
        uint256 weight; // Voting weight (basis points)
        uint256 lastUpdate; // Last update timestamp
        bool isActive; // Active status flag
    }

    /**
     * @notice Emitted when a new oracle is added to the aggregation system
     * @param oracle Address of the oracle contract being added
     * @param weight Voting weight assigned to this oracle (higher = more influence)
     */
    event OracleAdded(address indexed oracle, uint256 weight);

    /**
     * @notice Emitted when an oracle is removed from the system
     * @param oracle Address of the oracle contract being removed
     */
    event OracleRemoved(address indexed oracle);

    /**
     * @notice Emitted when an oracle's weight is updated
     * @param oracle Address of the oracle whose weight changed
     * @param newWeight New weight value in basis points
     */
    event OracleWeightUpdated(address indexed oracle, uint256 newWeight);

    /**
     * @notice Emitted when the aggregated price is updated
     * @param newPrice The newly calculated aggregated price
     * @param timestamp Block timestamp when price was calculated
     */
    event PriceUpdated(uint256 newPrice, uint256 timestamp);

    /**
     * @notice Emitted when an oracle is flagged as stale and excluded from aggregation
     * @param oracle Address of the oracle flagged as stale
     */
    event OracleFlaggedStale(address indexed oracle);

    /**
     * @notice Adds a new oracle to the aggregation system
     * @dev Only callable by governance. The oracle must implement IOracle interface
     *      and pass initial validation checks before being added to the active set.
     *
     * @param oracle Address of the oracle contract to add
     * @param weight Voting weight for this oracle (0-10000, where 10000 = 100%)
     *
     * Requirements:
     * - oracle MUST implement IOracle interface
     * - oracle MUST not already be in the system
     * - weight MUST be > 0 and ≤ 10000
     * - Caller MUST have ORACLE_MANAGER_ROLE
     * - Oracle MUST pass initial price validation
     */
    function addOracle(address oracle, uint256 weight) external;

    /**
     * @notice Removes an oracle from the aggregation system
     * @dev Only callable by governance. The oracle will immediately stop being used
     *      for price calculations. Emergency removal may be triggered automatically
     *      if an oracle becomes consistently stale or provides deviant data.
     *
     * @param oracle Address of the oracle contract to remove
     *
     * Requirements:
     * - oracle MUST currently be in the system
     * - Caller MUST have ORACLE_MANAGER_ROLE
     * - Removal MUST NOT leave fewer than minimum required oracles (typically 3)
     */
    function removeOracle(address oracle) external;

    /**
     * @notice Updates the weight of an existing oracle
     * @dev Weight changes take effect immediately for subsequent price calculations.
     *      Higher weights give the oracle more influence in median/average calculations.
     *
     * @param oracle Address of the oracle whose weight to update
     * @param newWeight New weight value (0-10000)
     *
     * Requirements:
     * - oracle MUST currently be in the system
     * - newWeight MUST be > 0 and ≤ 10000
     * - Caller MUST have ORACLE_MANAGER_ROLE
     */
    function updateOracleWeight(address oracle, uint256 newWeight) external;

    /**
     * @notice Retrieves the current aggregated price using median + TWAP methodology
     * @dev This is the primary function used by DRIController for reflective price updates.
     *      It performs the complete aggregation process:
     *      1. Queries all active oracles
     *      2. Filters out stale/invalid prices
     *      3. Calculates median to eliminate outliers
     *      4. Applies TWAP smoothing over configured window
     *      5. Validates final price against deviation thresholds
     *
     * The returned price is used directly by the reflective price update mechanism
     * and must be highly accurate and manipulation-resistant.
     *
     * @return price The final aggregated and smoothed price scaled to 18 decimals
     * @return timestamp The timestamp of the aggregated price calculation
     *
     * Requirements:
     * - MUST have at least 3 active, non-stale oracles
     * - Price MUST pass deviation checks (no single oracle > δ_max from median)
     * - TWAP window MUST contain sufficient data points
     * - Final price MUST be positive and reasonable (basic sanity checks)
     */
    function getAggregatedPrice() external view returns (uint256 price, uint256 timestamp);

    /**
     * @notice Retrieves historical TWAP data for the specified time window
     * @dev Allows analysis of price trends and volatility over time. Used by
     *      governance and monitoring systems to assess oracle performance.
     *
     * @param window Time window in seconds to calculate TWAP over
     * @return twapPrice The time-weighted average price over the specified window
     *
     * Requirements:
     * - window MUST be > 0 and ≤ maximum supported window (e.g., 24 hours)
     * - MUST have sufficient historical data for accurate calculation
     */
    function getTWAP(uint256 window) external view returns (uint256 twapPrice);

    /**
     * @notice Returns array of all registered oracle addresses
     * @dev Used for monitoring and governance purposes to see which oracles are configured
     * @return oracles Array of oracle contract addresses
     */
    function getOracles() external view returns (address[] memory oracles);

    /**
     * @notice Checks if a specific oracle is currently active in the system
     * @dev An oracle may be inactive due to staleness, manual deactivation, or failure
     * @param oracle Address of the oracle to check
     * @return isActive True if the oracle is active and being used for price aggregation
     */
    function isOracleActive(address oracle) external view returns (bool isActive);
}
