// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 * ██████╗  ██████╗  ██████╗ ████████╗███████╗████████╗██████╗  █████╗ ██████╗      ██████╗ ██████╗ ██╗     ██╗     ███████╗██████╗
 * ██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██╔══██╗    ██╔════╝██╔═══██╗██║     ██║     ██╔════╝██╔══██╗
 * ██████╔╝██║   ██║██║   ██║   ██║   ███████╗   ██║   ██████╔╝███████║██████╔╝    ██║     ██║   ██║██║     ██║     █████╗  ██████╔╝
 * ██╔══██╗██║   ██║██║   ██║   ██║   ╚════██║   ██║   ██╔══██╗██╔══██║██╔═══╝     ██║     ██║   ██║██║     ██║     ██╔══╝  ██╔══██╗
 * ██████╔╝╚██████╔╝╚██████╔╝   ██║   ███████║   ██║   ██║  ██║██║  ██║██║         ╚██████╗╚██████╔╝███████╗███████╗███████╗██║  ██║
 * ╚═════╝  ╚═════╝  ╚═════╝    ╚═╝   ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝          ╚═════╝ ╚═════╝ ╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝
 *
 * Bootstrap DRI Controller - System Orchestrator
 *
 * Central controller managing the Dynamic Reflective Index during bootstrap phase, coordinating
 * price updates, circuit breakers, and integration between DMM and PSM components.
 */

import "../interfaces/IDRIController.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IDMM.sol";
import "../interfaces/IPSM.sol";
import "../utils/FixedPointMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title BootstrapDRIController
 * @notice Central controller for the Dynamic Reflective Index (DRI) in bootstrap mode.
 * @dev Provides reflective price tracking, circuit breakers, and integration with
 *      DMM and PSM while avoiding circular dependencies during deployment.
 *      Key capabilities:
 *        - Reflective price updates with capped adjustments
 *        - Circuit breaker monitoring (warn/throttle/halt)
 *        - Optional direct integrations: DMM recentering and PSM arbitrage
 *        - Governance-controlled parameters via Ownable + AccessControl
 *        - Pausable emergency stop
 *        - Bootstrap setters for liquidity pool and PSM to resolve deployment order
 */
contract BootstrapDRIController is IDRIController, Ownable, ReentrancyGuard, AccessControl, Pausable {
    using FixedPointMath for uint256;

    /// @notice Configuration parameters for circuit breaker thresholds and persistence
    struct CircuitBreakerConfig {
        /// @notice Deviation in basis points to emit warnings
        uint256 warnThreshold;
        /// @notice Deviation in basis points to enter throttled mode
        uint256 throttleThreshold;
        /// @notice Deviation in basis points to halt the protocol
        uint256 haltThreshold;
        /// @notice Required blocks above warn threshold to register warning persistence
        uint256 warnBlocks;
        /// @notice Required blocks above throttle threshold to throttle
        uint256 throttleBlocks;
        /// @notice Required blocks above halt threshold to halt
        uint256 haltBlocks;
        /// @notice Blocks below warn threshold required to recover to normal
        uint256 recoverBlocks;
        /// @notice Minimum volume guard (reserved for future use)
        uint256 minVolume;
    }

    /// @notice Detailed record for deviation history
    struct PricePoint {
        /// @notice Block the record was taken
        uint256 blockNumber;
        /// @notice Signed deviation in basis points
        int256 deviation;
        /// @notice Timestamp of record
        uint256 timestamp;
    }

    /// @notice Oracle aggregator providing medianized/TWAP price
    IOracleAggregator public immutable oracleAggregator;

    /// @notice DMM pool address, settable once post-deploy to avoid circular deps
    address public liquidityPool;
    /// @notice True when liquidityPool has been set
    bool public liquidityPoolSet = false;

    /// @notice PSM address, settable once post-deploy to avoid circular deps
    address public pegStabilityModule;
    /// @notice True when PSM has been set
    bool public pegStabilityModuleSet = false;

    /// @notice Current reflective price (18 decimals)
    uint256 public reflectivePrice;
    /// @notice Timestamp of last successful sync
    uint256 public lastSyncTime;
    /// @notice Max basis-point adjustment allowed per update (Δ)
    uint256 public maxDeltaPerTick;
    /// @notice Minimum seconds between syncs (enforced unless every-block enabled)
    uint256 public syncInterval;
    /// @notice If true, bypasses syncInterval to allow per-block updates
    bool public everyBlockRebalancingEnabled;
    /// @notice Maximum allowed oracle staleness in seconds
    uint256 public maxOracleStaleness;
    /// @notice Feature flag for PSM execution from controller
    bool public enablePSMExecution;
    /// @notice Feature flag for DMM recentering from controller
    bool public enableDMMRecenter;

    /// @notice Circuit breaker configuration and state
    CircuitBreakerConfig public circuitBreakerConfig;
    /// @notice 0=normal, 1=warn, 2=throttle, 3=halt
    uint8 public currentCircuitBreakerLevel;
    /// @notice Block number when current breaker level activated
    uint256 public circuitBreakerActivatedAt;
    /// @notice Rolling absolute deviations (bps) used for persistence checks
    // Deviation history as a bounded ring buffer to avoid shifting costs
    mapping(uint256 => uint256) public deviationRingBuffer; // index => deviation bps
    uint256 public deviationHead; // next write index
    uint256 public deviationCount; // number of valid entries (capped at MAX_DEVIATION_HISTORY)
    uint256 public constant MAX_DEVIATION_HISTORY = 50;

    /// @notice Historical price points for monitoring
    PricePoint[] public priceHistory;

    /// @notice Role allowed to call syncPrice (automation/keepers)
    bytes32 public constant SYNC_ROLE = keccak256("SYNC_ROLE");

    /// @notice Emitted when liquidity pool is set
    event LiquidityPoolSet(address indexed liquidityPool);
    /// @notice Emitted when bootstrap mode is disabled (stricter thresholds)
    event BootstrapModeDisabled();
    event PegStabilityModuleSet(address indexed psm);
    /// @notice Emitted on successful PSM execution path
    event PSMExecutedBootstrap(bool isBuy, uint256 amountIn, uint256 amountOut);
    /// @notice Emitted on parameter updates via governance
    event ParameterUpdated(string indexed parameter, uint256 oldValue, uint256 newValue);
    /// @notice Emitted when circuit breaker config is updated
    event CircuitBreakerConfigUpdated(CircuitBreakerConfig newConfig);
    /// @notice Emitted when circuit breaker is manually overridden
    event EmergencyCircuitBreakerOverride(uint8 oldLevel, uint8 newLevel);
    event RecenterCheckFailed();
    event RecenterFailed(string reason);
    event RecenterComplete(uint256 timestamp);

    /// @notice Restricts access to owner, self calls, and SYNC_ROLE
    modifier onlyAuthorized() {
        require(
            msg.sender == owner() ||
            msg.sender == address(this) ||
            hasRole(SYNC_ROLE, msg.sender),
            "Not authorized"
        );
        _;
    }

    /// @notice Blocks execution when circuit breaker is at halt level
    modifier whenNotHalted() {
        require(currentCircuitBreakerLevel < 3, "Protocol is halted");
        _;
    }

    /// @notice Ensures the liquidity pool has been set before proceeding
    modifier whenLiquidityPoolSet() {
        require(liquidityPoolSet, "Liquidity pool not set");
        _;
    }

    /// @notice Initializes controller in bootstrap mode
    /// @param _oracleAggregator Address of oracle aggregator
    /// @param _initialPrice Initial reflective price (18 decimals)
    /// @param _owner Governance owner (Governor)
    /// @param _pegStabilityModule Optional PSM address (can be set later)
    constructor(
        address _oracleAggregator,
        uint256 _initialPrice,
        address _owner,
        address _pegStabilityModule
    ) Ownable(_owner) {
        require(_oracleAggregator != address(0), "Invalid oracle aggregator");
        require(_initialPrice > 0, "Initial price must be positive");
        require(_owner != address(0), "Invalid owner address");
        // PSM can be set later to resolve circular dependencies

        oracleAggregator = IOracleAggregator(_oracleAggregator);
        if (_pegStabilityModule != address(0)) {
            pegStabilityModule = _pegStabilityModule;
            pegStabilityModuleSet = true;
        }
        reflectivePrice = _initialPrice;
        lastSyncTime = block.timestamp;
        maxDeltaPerTick = 300; // 3%
        syncInterval = 30; // 30 seconds
        currentCircuitBreakerLevel = 0;
        everyBlockRebalancingEnabled = false;
        maxOracleStaleness = 300; // 5 minutes default
        enablePSMExecution = true;
        enableDMMRecenter = true;

        // Production-aligned circuit breaker config
        circuitBreakerConfig = CircuitBreakerConfig({
            warnThreshold: 100, // 1%
            throttleThreshold: 200, // 2%
            haltThreshold: 500, // 5%
            warnBlocks: 10,
            throttleBlocks: 20,
            haltBlocks: 50,
            recoverBlocks: 100,
            minVolume: 1000e6
        });

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _setRoleAdmin(SYNC_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(SYNC_ROLE, _owner);

        emit ReflectivePriceUpdated(_initialPrice, block.timestamp);
    }

    /**
     * @notice Sets the DMM liquidity pool address
     * @dev Callable once during bootstrap to resolve deployment order
     * @param _liquidityPool Address of the DMM pool
     */
    function setLiquidityPool(address _liquidityPool) external onlyOwner {
        require(!liquidityPoolSet, "Liquidity pool already set");
        require(_liquidityPool != address(0), "Invalid liquidity pool address");

        liquidityPool = _liquidityPool;
        liquidityPoolSet = true;

        emit LiquidityPoolSet(_liquidityPool);
    }

    /**
     * @notice Synchronize reflective price using oracle data and trigger integrations
     * @dev Steps:
     *      1) Enforce timing and staleness requirements
     *      2) Compute capped adjustment and update reflective price
     *      3) Compute deviation, update history, evaluate circuit breakers
     *      4) Optionally recenter DMM or execute PSM based on deviation thresholds
     */
    function syncPrice()
        external
        override
        onlyAuthorized
        whenNotHalted
        whenLiquidityPoolSet
        nonReentrant
    whenNotPaused
    {
        // Enforce sync interval unless every-block rebalancing is enabled
        if (!everyBlockRebalancingEnabled) {
            require(block.timestamp >= lastSyncTime + syncInterval, "Sync interval not elapsed");
        }

        // Get oracle price and enforce freshness
        (uint256 oraclePrice, uint256 oracleTimestamp) = oracleAggregator.getAggregatedPrice();
        require(oraclePrice > 0, "Invalid oracle price");
        // Validate oracle timestamp not in the future
        require(oracleTimestamp <= block.timestamp, "Oracle timestamp in future");
        // Tight staleness check aligned with production controller (configurable)
        require(block.timestamp - oracleTimestamp <= maxOracleStaleness, "Oracle data too stale");

        // Update reflective price with capped adjustment
        uint256 previousReflectivePrice = reflectivePrice;
        uint256 rawFactor = oraclePrice.div(previousReflectivePrice);

        // Apply symmetric caps around 1.0 in fixed-point
        uint256 adjustmentCap = FixedPointMath.SCALE * maxDeltaPerTick / 10000;
        uint256 upperBound = FixedPointMath.SCALE + adjustmentCap;
        uint256 lowerBound = FixedPointMath.SCALE - adjustmentCap;

        uint256 cappedFactor;
        if (rawFactor > upperBound) {
            cappedFactor = upperBound;
        } else if (rawFactor < lowerBound) {
            cappedFactor = lowerBound;
        } else {
            cappedFactor = rawFactor;
        }

        reflectivePrice = previousReflectivePrice.mul(cappedFactor).div(FixedPointMath.SCALE);
        lastSyncTime = block.timestamp;

        // Get market price and calculate deviation
        uint256 marketPrice = _getMarketPrice();
        int256 deviation = _calculateDeviation(marketPrice, reflectivePrice);

        // Update deviation history and evaluate circuit breakers
        uint256 absDeviation = deviation >= 0 ? uint256(deviation) : uint256(-deviation);
        _updateDeviationHistory(absDeviation);
        _evaluateCircuitBreakers(absDeviation);

        // Record price history
        priceHistory.push(PricePoint({
            blockNumber: block.number,
            deviation: deviation,
            timestamp: block.timestamp
        }));

        // Prevent unlimited array growth
        if (priceHistory.length > 1000) {
            for (uint256 i = 0; i < priceHistory.length - 1; i++) {
                priceHistory[i] = priceHistory[i + 1];
            }
            priceHistory.pop();
        }

        // Emit events and trigger PSM/DMM integration per thresholds:
        // - PSM for 10 bps <= deviation < 70 bps
        // - DMM recentering for deviation >= 70 bps

        if (absDeviation >= 70) { // 0.70%
            emit BandShifted(reflectivePrice, 70, deviation);
            // Try direct DMM recentering if available
            if (enableDMMRecenter) {
                try IDMM(liquidityPool).canRecenter() returns (bool canRecenter) {
                    if (canRecenter) {
                        try IDMM(liquidityPool).recentBand() {
                            emit RecenterComplete(block.timestamp);
                        } catch Error(string memory reason) {
                            emit RecenterFailed(reason);
                            revert(string(abi.encodePacked("Recentering failed: ", reason)));
                        } catch {
                            emit RecenterFailed("unknown");
                            revert("Recentering failed: unknown");
                        }
                    }
                } catch {
                    emit RecenterCheckFailed();
                    revert("Cannot check recenter status");
                }
            }
            // Optional fallback: if DMM cannot recenter or is disabled, attempt PSM
            if (enablePSMExecution && pegStabilityModuleSet && currentCircuitBreakerLevel < 3) {
                try IPSM(pegStabilityModule).executeArbSwap(deviation > 0, 0) returns (uint256 amountOutHigh) {
                    emit PSMExecutedBootstrap(deviation > 0, 0, amountOutHigh);
                } catch {
                    emit PSMSwapPending(absDeviation);
                }
            }
        } else if (absDeviation >= 10) { // 0.10% up to but excluding 0.70%
            // Attempt direct PSM arbitrage; fallback to event if it fails
            if (currentCircuitBreakerLevel < 3 && pegStabilityModuleSet && enablePSMExecution) {
                try IPSM(pegStabilityModule).executeArbSwap(deviation > 0, 0) returns (uint256 amountOut) {
                        emit PSMExecutedBootstrap(deviation > 0, 0, amountOut);
                } catch {
                    emit PSMSwapPending(absDeviation);
                }
            } else {
                emit PSMSwapPending(absDeviation);
            }
        }

        emit ReflectivePriceUpdated(reflectivePrice, block.timestamp);
        emit DeviationCheck(
            block.timestamp,
            marketPrice,
            reflectivePrice,
            deviation,
            circuitBreakerConfig.warnThreshold
        );

        if (absDeviation >= circuitBreakerConfig.warnThreshold && currentCircuitBreakerLevel == 0) {
            emit DeviationWarning(block.timestamp, absDeviation);
        }
    }

    /// @notice Returns current reflective price
    function getReflectivePrice() external view override returns (uint256) {
        return reflectivePrice;
    }

    /// @notice Returns current market price from DMM or reflective fallback
    function getMarketPrice() external view override returns (uint256) {
        return _getMarketPrice();
    }

    /// @notice Returns signed basis-point deviation between market and reflective price
    function getDeviation() external view override returns (int256) {
        if (!liquidityPoolSet) return 0;
        uint256 marketPrice = _getMarketPrice();
        return _calculateDeviation(marketPrice, reflectivePrice);
    }

    /// @notice Returns whether any circuit breaker level is active and its level
    function isCircuitBreakerActive() external view override returns (bool isActive, uint8 level) {
        return (currentCircuitBreakerLevel > 0, currentCircuitBreakerLevel);
    }

    /**
     * @notice Disables bootstrap mode and applies stricter production parameters
     */
    function disableBootstrapMode() external onlyOwner {
        require(liquidityPoolSet, "Must set liquidity pool first");

        // Update to production thresholds
        circuitBreakerConfig.warnThreshold = 100; // 1%
        circuitBreakerConfig.throttleThreshold = 200; // 2%
        circuitBreakerConfig.haltThreshold = 500; // 5%

        // Reduce sync interval for more responsive updates
        syncInterval = 15; // 15 seconds
        everyBlockRebalancingEnabled = false; // Ensure interval is enforced in production mode

        emit BootstrapModeDisabled();
    }

    /// @notice Sets the PSM address (one-time)
    /// @param _psm Address of the PSM
    function setPegStabilityModule(address _psm) external onlyOwner {
        require(!pegStabilityModuleSet, "PSM already set");
        require(_psm != address(0), "Invalid PSM address");
        pegStabilityModule = _psm;
        pegStabilityModuleSet = true;
        emit PegStabilityModuleSet(_psm);
    }

    // Hardening: Admin functions
    /// @notice Pause controller operations (emergency stop)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause controller operations
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Sets maximum allowed oracle staleness in seconds
    /// @param newMax New staleness limit (60–1800 seconds)
    function setMaxOracleStaleness(uint256 newMax) external onlyOwner {
        require(newMax >= 60 && newMax <= 1800, "Staleness 60-1800s");
        uint256 old = maxOracleStaleness;
        maxOracleStaleness = newMax;
        emit ParameterUpdated("maxOracleStaleness", old, newMax);
    }

    /// @notice Toggle feature flags for DMM recentering and PSM execution
    /// @param dmmRecenter Enable or disable DMM recenter calls
    /// @param psmExecution Enable or disable PSM arbitrage calls
    function setFeatureFlags(bool dmmRecenter, bool psmExecution) external onlyOwner {
        bool oldDmm = enableDMMRecenter;
        bool oldPsm = enablePSMExecution;
        enableDMMRecenter = dmmRecenter;
        enablePSMExecution = psmExecution;
        emit ParameterUpdated("enableDMMRecenter", oldDmm ? 1 : 0, dmmRecenter ? 1 : 0);
        emit ParameterUpdated("enablePSMExecution", oldPsm ? 1 : 0, psmExecution ? 1 : 0);
    }

    /// @notice Enable/disable every-block rebalancing (bypasses syncInterval)
    /// @param enabled True to enable, false to enforce interval
    function setEveryBlockRebalancing(bool enabled) external onlyOwner {
        bool oldVal = everyBlockRebalancingEnabled;
        everyBlockRebalancingEnabled = enabled;
        emit ParameterUpdated("everyBlockRebalancingEnabled", oldVal ? 1 : 0, enabled ? 1 : 0);
    }

    /// @notice Internal helper to read current market price or fallback to reflective
    function _getMarketPrice() internal view returns (uint256) {
        if (!liquidityPoolSet) {
            return reflectivePrice; // Return reflective price as fallback
        }

        try IDMM(liquidityPool).getCurrentPrice() returns (uint256 price) {
            require(price > 0, "Invalid DMM price");
            return price;
        } catch {
            return reflectivePrice; // Fallback to reflective price
        }
    }

    /// @notice Internal helper to compute signed deviation in basis points
    function _calculateDeviation(uint256 marketPrice, uint256 refPrice) internal pure returns (int256) {
        if (marketPrice == 0 || refPrice == 0) return 0;

        int256 priceDiff = int256(marketPrice) - int256(refPrice);
        return (priceDiff * 10000) / int256(refPrice);
    }

    /// @notice Internal helper to append deviation and prune history
    function _updateDeviationHistory(uint256 deviation) internal {
        // Maintain strict chronological order: newest at the end
        // Write into ring buffer
        deviationRingBuffer[deviationHead] = deviation;
        deviationHead = (deviationHead + 1) % MAX_DEVIATION_HISTORY;
        if (deviationCount < MAX_DEVIATION_HISTORY) {
            deviationCount += 1;
        }
    }

    /// @notice Internal helper to evaluate and update circuit breaker state
    function _evaluateCircuitBreakers(uint256 currentDeviation) internal {
        CircuitBreakerConfig memory config = circuitBreakerConfig;
        uint256 historyLength = deviationCount;

        if (historyLength == 0) {
            return; // nothing to evaluate yet
        }

        // Calculate max recent deviation and block counts
        (uint256 maxRecentDeviation, uint256 blocksAboveHalt, uint256 blocksAboveThrottle, uint256 blocksAboveWarn) =
            _calculateDeviationMetrics(currentDeviation, config, historyLength);

        // Determine new circuit breaker level
        uint8 newLevel = _determineCircuitBreakerLevel(
            maxRecentDeviation,
            blocksAboveHalt,
            blocksAboveThrottle,
            blocksAboveWarn,
            config
        );

        // Handle level changes
        _handleCircuitBreakerLevelChange(newLevel, maxRecentDeviation, config, historyLength);
    }

    function _calculateDeviationMetrics(
        uint256 currentDeviation,
        CircuitBreakerConfig memory config,
        uint256 historyLength
    ) internal view returns (uint256 maxRecentDeviation, uint256 blocksAboveHalt, uint256 blocksAboveThrottle, uint256 blocksAboveWarn) {
        maxRecentDeviation = currentDeviation;
        uint256 checkLength = historyLength < config.haltBlocks ? historyLength : config.haltBlocks;

        // Find max deviation in recent history
        for (uint256 i = 0; i < checkLength; i++) {
            uint256 idx = ( (deviationHead + MAX_DEVIATION_HISTORY) - 1 - i ) % MAX_DEVIATION_HISTORY;
            uint256 entry = deviationRingBuffer[idx];
            if (entry > maxRecentDeviation) maxRecentDeviation = entry;
        }

        // Count blocks above each threshold
        uint256 blocksToCheck = historyLength < config.haltBlocks ? historyLength : config.haltBlocks;
        for (uint256 i = 0; i < blocksToCheck; i++) {
            uint256 idx2 = ( (deviationHead + MAX_DEVIATION_HISTORY) - 1 - i ) % MAX_DEVIATION_HISTORY;
            uint256 historicalDeviation = deviationRingBuffer[idx2];
            if (historicalDeviation >= config.haltThreshold) blocksAboveHalt++;
            if (historicalDeviation >= config.throttleThreshold) blocksAboveThrottle++;
            if (historicalDeviation >= config.warnThreshold) blocksAboveWarn++;
        }
    }

    function _determineCircuitBreakerLevel(
        uint256 maxRecentDeviation,
        uint256 blocksAboveHalt,
        uint256 blocksAboveThrottle,
        uint256 blocksAboveWarn,
        CircuitBreakerConfig memory config
    ) internal pure returns (uint8 newLevel) {
        if (blocksAboveHalt >= config.haltBlocks && maxRecentDeviation >= config.haltThreshold) {
            return 3;
        } else if (blocksAboveThrottle >= config.throttleBlocks && maxRecentDeviation >= config.throttleThreshold) {
            return 2;
        } else if (blocksAboveWarn >= config.warnBlocks && maxRecentDeviation >= config.warnThreshold) {
            return 1;
        }
        return 0;
    }

    function _handleCircuitBreakerLevelChange(
        uint8 newLevel,
        uint256 maxRecentDeviation,
        CircuitBreakerConfig memory config,
        uint256 historyLength
    ) internal {
        if (newLevel > currentCircuitBreakerLevel) {
            currentCircuitBreakerLevel = newLevel;
            circuitBreakerActivatedAt = block.number;
            emit CircuitBreakerTriggered(newLevel, maxRecentDeviation);
        } else if (newLevel < currentCircuitBreakerLevel) {
            // Check recovery conditions
            if (_canRecover(config, historyLength)) {
                currentCircuitBreakerLevel = 0;
                circuitBreakerActivatedAt = 0;
                emit CircuitBreakerReleased();
            }
        }
    }

    function _canRecover(CircuitBreakerConfig memory config, uint256 historyLength) internal view returns (bool) {
        uint256 validHistory = historyLength < MAX_DEVIATION_HISTORY ? historyLength : MAX_DEVIATION_HISTORY;
        if (validHistory < config.recoverBlocks) {
            return false; // Not enough valid history
        }

        uint256 checkCount = config.recoverBlocks < validHistory ? config.recoverBlocks : validHistory;
        for (uint256 i = 0; i < checkCount; i++) {
            uint256 idx3 = ( (deviationHead + MAX_DEVIATION_HISTORY) - 1 - i ) % MAX_DEVIATION_HISTORY;
            uint256 entry3 = deviationRingBuffer[idx3];
            if (entry3 >= config.warnThreshold) {
                return false;
            }
        }
        return true;
    }

    // Admin functions for configuration updates
    /// @notice Set minimum sync interval in seconds
    /// @param newInterval New interval (10–300 seconds)
    function setSyncInterval(uint256 newInterval) external onlyOwner {
        require(newInterval >= 10 && newInterval <= 300, "Interval must be 10s to 5min");
        uint256 oldInterval = syncInterval;
        syncInterval = newInterval;
        emit ParameterUpdated("syncInterval", oldInterval, newInterval);
    }

    /// @notice Set max per-tick adjustment (basis points)
    /// @param newMaxDelta New max delta in bps (1–5000)
    function setMaxDeltaPerTick(uint256 newMaxDelta) external onlyOwner {
        require(newMaxDelta > 0 && newMaxDelta <= 5000, "Delta must be 0.01% to 50%");
        uint256 oldDelta = maxDeltaPerTick;
        maxDeltaPerTick = newMaxDelta;
        emit ParameterUpdated("maxDeltaPerTick", oldDelta, newMaxDelta);
    }

    /// @notice Update circuit breaker configuration
    /// @param newConfig Struct with new thresholds and persistence values
    function setCircuitBreakerConfig(CircuitBreakerConfig calldata newConfig) external onlyOwner {
        require(newConfig.warnThreshold > 0, "Warning threshold must be positive");
        require(newConfig.throttleThreshold >= newConfig.warnThreshold, "Throttle >= warn");
        require(newConfig.haltThreshold >= newConfig.throttleThreshold, "Halt >= throttle");
        require(newConfig.recoverBlocks > 0, "Recovery blocks must be positive");
        require(newConfig.haltBlocks <= MAX_DEVIATION_HISTORY, "haltBlocks > history");
        require(newConfig.warnBlocks <= MAX_DEVIATION_HISTORY, "warnBlocks > history");
        require(newConfig.throttleBlocks <= MAX_DEVIATION_HISTORY, "throttleBlocks > history");
        require(newConfig.haltThreshold <= 10000 && newConfig.throttleThreshold <= 10000 && newConfig.warnThreshold <= 10000, "thresholds > 100%");
        circuitBreakerConfig = newConfig;
        emit CircuitBreakerConfigUpdated(newConfig);
    }

    // Emergency recovery functions
    /// @notice Clear circuit breaker state immediately
    function emergencyResetCircuitBreaker() external onlyOwner {
        currentCircuitBreakerLevel = 0;
        circuitBreakerActivatedAt = 0;
        emit CircuitBreakerReleased();
    }

    /// @notice Manually set reflective price during throttle/halt
    /// @param newPrice New reflective price (18 decimals)
    function emergencySetReflectivePrice(uint256 newPrice) external onlyOwner {
        require(newPrice > 0, "Invalid price");
        require(currentCircuitBreakerLevel >= 2, "Can only use during throttle/halt");

        reflectivePrice = newPrice;
        lastSyncTime = block.timestamp;
        emit ReflectivePriceUpdated(newPrice, block.timestamp);
    }

    /// @notice Manually override circuit breaker level (0–3)
    /// @param level New circuit breaker level
    function emergencySetCircuitBreakerLevel(uint8 level) external onlyOwner {
        require(level <= 3, "Invalid circuit breaker level");
        uint8 oldLevel = currentCircuitBreakerLevel;
        currentCircuitBreakerLevel = level;
        if (level == 0) {
            circuitBreakerActivatedAt = 0;
            emit CircuitBreakerReleased();
        } else {
            circuitBreakerActivatedAt = block.number;
            emit CircuitBreakerTriggered(level, 0);
        }
        emit EmergencyCircuitBreakerOverride(oldLevel, level);
    }
}
