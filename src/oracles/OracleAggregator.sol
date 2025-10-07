// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 *  ██████╗ ██████╗  █████╗  ██████╗██╗     ███████╗     █████╗  ██████╗  ██████╗ ██████╗ ███████╗ ██████╗  █████╗ ████████╗ ██████╗ ██████╗
 * ██╔═══██╗██╔══██╗██╔══██╗██╔════╝██║     ██╔════╝    ██╔══██╗██╔════╝ ██╔════╝ ██╔══██╗██╔════╝██╔════╝ ██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗
 * ██║   ██║██████╔╝███████║██║     ██║     █████╗      ███████║██║  ███╗██║  ███╗██████╔╝█████╗  ██║  ███╗███████║   ██║   ██║   ██║██████╔╝
 * ██║   ██║██╔══██╗██╔══██║██║     ██║     ██╔══╝      ██╔══██║██║   ██║██║   ██║██╔══██╗██╔══╝  ██║   ██║██╔══██║   ██║   ██║   ██║██╔══██╗
 * ╚██████╔╝██║  ██║██║  ██║╚██████╗███████╗███████╗    ██║  ██║╚██████╔╝╚██████╔╝██║  ██║███████╗╚██████╔╝██║  ██║   ██║   ╚██████╔╝██║  ██║
 *  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚══════╝╚══════╝    ╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝
 *
 * Oracle Aggregator - MAAG Index Price Feed
 *
 * Aggregates price data from multiple oracle sources for META, AAPL, AMZN, GOOGL (MAAG) basket,
 * providing robust median-based pricing with staleness checks and deviation detection.
 */

import "../interfaces/IOracle.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMAAGOracle {
    function getMAAGIndex() external view returns (uint256 averagePrice, uint256 timestamp, uint256 activeFeeds, uint256 totalValue);
    function getAllPrices() external view returns (bytes32[] memory feedIds, uint256[] memory prices, uint256[] memory timestamps, bool[] memory isActive);
}

contract OracleAggregator is AccessControl, ReentrancyGuard {

    bytes32 public constant GOV_ROLE = keccak256("GOV_ROLE");

    IMAAGOracle public immutable maagOracle;

    // Events
    event OracleAdded(address indexed oracle, uint256 weight);
    event OracleRemoved(address indexed oracle);
    event OracleWeightUpdated(address indexed oracle, uint256 newWeight);
    event PriceUpdated(uint256 newPrice, uint256 timestamp);
    event AggregatePrice(uint256 priceX18, uint256 timestamp, uint8 nUsed, uint8 flags);
    event SourceFiltered(address indexed oracle, uint256 price, uint64 timestamp, uint8 reason);

    struct PricePoint {
        uint256 priceX18;
        uint64 timestamp;
    }

    struct SourceConfig {
        address oracle;      // slot 1
        uint64 lastUpdate;
        uint32 maxAge;       // per-source staleness threshold (seconds)
        uint16 weight;       // assume <=65535, or use bps
        uint16 maxDeviationBps;  // per-source deviation limit (basis points)
        bool isActive;       // packs into slot 2
    }

    mapping(address => SourceConfig) public oracles;
    address[] public oracleList;

    // Ring buffer for chronologically ordered history
    uint256 public constant HIST = 1024;
    uint8 public constant MAX_ORACLES = 49;

    // Status flags
    uint8 public constant OK = 0;
    uint8 public constant LOW_QUORUM = 1;
    uint8 public constant STALE = 2;
    uint8 public constant DEVIANT_VS_TWAP = 3;
    PricePoint[HIST] public priceHistory;
    uint16 public histLen;
    uint16 public histHead; // points to newest

    // Configurable parameters
    uint16 public minQuorum = 3;
    uint32 public aggregateMaxAge = 900; // 15 minutes
    uint16 public maxDeviationFromTwapBps = 1500; // 15%
    uint16 public maagMinQuorum = 2; // Minimum feeds for MAAG fallback

    uint256 public totalWeight;
    uint256 public lastUpdateTime;
    uint256 public activeCount; // Cache for gas efficiency
    bool public bootstrapped; // Protection during initial setup

    modifier onlyGovernance() {
        _checkRole(GOV_ROLE);
        _;
    }

    constructor(address _governance, address _maagOracle) {
        _grantRole(GOV_ROLE, _governance);
        _grantRole(DEFAULT_ADMIN_ROLE, _governance);
        maagOracle = IMAAGOracle(_maagOracle);
        lastUpdateTime = block.timestamp;
    }

    function addOracleAdvanced(
        address oracle,
        uint256 weight,
        uint256 maxAge,
        uint256 maxDeviationBps
    ) external onlyGovernance {
        require(oracle != address(0), "Invalid oracle address");
        require(weight > 0 && weight <= 10000, "Invalid weight range");
        require(maxAge > 0 && maxAge <= 1 days, "Invalid max age");
        require(maxDeviationBps <= 5000, "Max deviation too large"); // 50% max
        require(!oracles[oracle].isActive, "Oracle already active");
        require(oracleList.length < MAX_ORACLES, "Too many oracles");

        oracles[oracle] = SourceConfig({
            oracle: oracle,
            weight: uint16(weight),
            maxAge: uint32(maxAge),
            maxDeviationBps: uint16(maxDeviationBps),
            lastUpdate: uint64(block.timestamp),
            isActive: true
        });

        oracleList.push(oracle);
        totalWeight += weight;
        activeCount++;

        emit OracleAdded(oracle, weight);
    }

    // Interface implementation
    function addOracle(address oracle, uint256 weight) external onlyGovernance {
        require(oracle != address(0), "Invalid oracle address");
        require(weight > 0 && weight <= 10000, "Invalid weight range");
        require(!oracles[oracle].isActive, "Oracle already active");
        require(oracleList.length < MAX_ORACLES, "Too many oracles");

        // Use default values: 15 minutes staleness, 5% deviation
        oracles[oracle] = SourceConfig({
            oracle: oracle,
            weight: uint16(weight),
            maxAge: uint32(900), // 15 minutes
            maxDeviationBps: uint16(500), // 5%
            lastUpdate: uint64(block.timestamp),
            isActive: true
        });

        oracleList.push(oracle);
        totalWeight += weight;
        activeCount++;

        emit OracleAdded(oracle, weight);
    }

    uint256 public constant REMOVAL_GRACE_PERIOD = 24 hours;
    mapping(address => uint256) public oracleRemovalTimestamp;

    function proposeOracleRemoval(address oracle) external onlyGovernance {
        require(oracles[oracle].isActive, "Oracle not active");
        oracleRemovalTimestamp[oracle] = block.timestamp;
    }

    function executeOracleRemoval(address oracle) external onlyGovernance {
        require(oracles[oracle].isActive, "Oracle not active");
        require(oracleRemovalTimestamp[oracle] > 0, "Removal not proposed");
        require(block.timestamp >= oracleRemovalTimestamp[oracle] + REMOVAL_GRACE_PERIOD, "Grace period not met");

        // Re-check functional redundancy strictly above quorum to tolerate immediate failures
        uint256 functionalCount = 0;
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracleList[i] != oracle && oracles[oracleList[i]].isActive) {
                try IOracle(oracleList[i]).viewPrice() returns (uint256, uint256) {
                    functionalCount++;
                } catch {}
            }
        }
        require(functionalCount >= minQuorum + 1, "Need redundancy above quorum");

        // Proceed with removal
        totalWeight -= oracles[oracle].weight;
        oracles[oracle].isActive = false;
        activeCount--;

        // Remove from oracle list
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracleList[i] == oracle) {
                oracleList[i] = oracleList[oracleList.length - 1];
                oracleList.pop();
                break;
            }
        }

        delete oracleRemovalTimestamp[oracle];
        emit OracleRemoved(oracle);
    }

    function updateOracleWeight(address oracle, uint256 newWeight) external onlyGovernance {
        require(oracles[oracle].isActive, "Oracle not active");
        require(newWeight > 0 && newWeight <= 10000, "Invalid weight range");

        uint16 newWeight16 = uint16(newWeight);
        totalWeight = totalWeight - oracles[oracle].weight + newWeight16;
        oracles[oracle].weight = newWeight16;

        emit OracleWeightUpdated(oracle, newWeight);
    }

    function setMinQuorum(uint16 newQuorum) external onlyGovernance {
        require(newQuorum >= 3 && newQuorum <= 10, "Invalid quorum range - minimum 3 oracles required");
        require(newQuorum <= activeCount, "Cannot set quorum higher than active oracles");
        minQuorum = newQuorum;
    }

    function setAggregateMaxAge(uint32 newMaxAge) external onlyGovernance {
        require(newMaxAge <= 1 days, "Max age too large");
        aggregateMaxAge = newMaxAge;
    }

    function setMaxDeviationFromTwapBps(uint16 newMaxDeviation) external onlyGovernance {
        require(newMaxDeviation <= 5000, "Max deviation too large"); // 50% max
        maxDeviationFromTwapBps = newMaxDeviation;
    }

    function setMaagMinQuorum(uint16 newMaagQuorum) external onlyGovernance {
        require(newMaagQuorum >= 1 && newMaagQuorum <= 4, "Invalid MAAG quorum range");
        maagMinQuorum = newMaagQuorum;
    }

    function seedInitialPrice(uint256 price, uint256 timestamp) external onlyGovernance {
        require(!bootstrapped, "Already bootstrapped");
        require(price > 0, "Invalid price");
        require(timestamp <= block.timestamp, "Future timestamp");

        _addPricePoint(price, timestamp);
        lastUpdateTime = timestamp;
        bootstrapped = true;

        emit PriceUpdated(price, timestamp);
    }


    // Reason codes: 1=stale, 2=deviant, 3=failed

    function _calculateMAAGManually() internal view returns (uint256 price, uint256 timestamp) {
        // Get individual prices from MAAG oracle directly
        // Based on the actual data: META, AAPL, GOOG, AMZN
        uint256 sum = 0;
        uint256 count = 0;
        uint256 latestTimestamp = 0;

        // Call individual price functions
        try maagOracle.getAllPrices() returns (
            bytes32[] memory, // feedIds (unused)
            uint256[] memory prices,
            uint256[] memory timestamps,
            bool[] memory isActive
        ) {
            for (uint256 i = 0; i < prices.length; i++) {
                // Add staleness and activity checks
                if (prices[i] == 0 || !isActive[i] || timestamps[i] == 0 || block.timestamp - timestamps[i] > aggregateMaxAge) continue;

                sum += prices[i];
                count++;
                if (timestamps[i] > latestTimestamp) {
                    latestTimestamp = timestamps[i];
                }
            }

            require(count >= maagMinQuorum, "Insufficient MAAG quorum");
            return (sum / count, latestTimestamp > 0 ? latestTimestamp : block.timestamp);
        } catch {
            // If getAllPrices fails, revert instead of returning hardcoded price
            // This ensures system doesn't continue with stale or incorrect price data
            revert("Oracle aggregation failed - no reliable price data available");
        }
    }

    function getTWAP(uint256 window) external view returns (uint256) {
        return _twap(window);
    }

    function getAggregatedPrice() external view returns (uint256 price, uint256 timestamp) {
        (price, timestamp,) = _getMedianPriceWithFlags();
    }

    function getAggregatedPriceWithFlags() external view returns (uint256 price, uint256 timestamp, uint8 flags) {
        (price, timestamp, flags,) = _getMedianPriceWithFlagsAndCount();
    }

    function _twap(uint256 window) internal view returns (uint256) {
        if (histLen == 0) return 0;
        uint64 cutoff = block.timestamp > window ? uint64(block.timestamp - window) : 0;
        uint256 sum; uint256 dtSum;

        // iterate backwards; array remains in chronological order via ring buffer
        uint16 i = histHead;
        uint16 seen;

        while (seen < histLen) {
            PricePoint memory p = priceHistory[i];
            if (p.timestamp <= cutoff) break;

            uint64 prevT = (seen == 0 || histLen <= 1 || (histLen > 1 && seen >= histLen-1)) ? cutoff : priceHistory[(i+HIST-1)%HIST].timestamp;
            uint256 dt = p.timestamp > prevT ? p.timestamp - prevT : 1;
            sum += p.priceX18 * dt;
            dtSum += dt;
            i = uint16((i + HIST - 1) % HIST);
            seen++;
        }
        return dtSum == 0 ? priceHistory[histHead].priceX18 : sum / dtSum;
    }

    function updatePrice() external nonReentrant {
        // Use mutative version that emits events
        (uint256 newPrice, uint256 timestamp, uint8 flags, uint256 usedSources) = _aggregateWithEvents();

        // Only update if price is valid (flags == OK)
        require(flags == OK && newPrice > 0, "Invalid oracle data");

        _addPricePoint(newPrice, timestamp);
        lastUpdateTime = timestamp;

        // Mark as bootstrapped after first successful update
        if (!bootstrapped) {
            bootstrapped = true;
        }

        emit AggregatePrice(newPrice, timestamp, uint8(usedSources), flags);
        emit PriceUpdated(newPrice, timestamp);
    }

    function _aggregateWithEvents() internal returns (uint256 price, uint256 timestamp, uint8 flags, uint256 validPrices) {
        uint256 currentActiveCount = getActiveOracleCount();

        // SECURITY FIX: Enforce strict minimum quorum requirements
        if (currentActiveCount < minQuorum) {
            return (0, 0, LOW_QUORUM, 0);
        }

        uint256[] memory prices = new uint256[](oracleList.length);
        uint256[] memory weights = new uint256[](oracleList.length);
        uint64[] memory timestamps = new uint64[](oracleList.length);
        uint256 validCount = 0;

        uint256 center = _center();

        // Bootstrap protection: only when explicitly not bootstrapped
        // If no center but we have oracles, allow normal aggregation without deviation checks

        for (uint256 i = 0; i < oracleList.length; i++) {
            address oracleAddr = oracleList[i];
            SourceConfig memory config = oracles[oracleAddr];
            if (!config.isActive) continue;

            try IOracle(oracleAddr).viewPrice() returns (uint256 oraclePrice, uint256 oracleTimestamp) {
                // Reject future timestamps explicitly
                if (oracleTimestamp > block.timestamp) {
                    emit SourceFiltered(oracleAddr, oraclePrice, uint64(oracleTimestamp), 4); // 4=future
                    continue;
                }

                // Use per-source staleness check
                if (_isStaleForSource(oracleTimestamp, config.maxAge)) {
                    emit SourceFiltered(oracleAddr, oraclePrice, uint64(oracleTimestamp), 1); // 1=stale
                    continue;
                }

                // Use per-source deviation check
                if (_isOutlierForSource(oraclePrice, center, config.maxDeviationBps)) {
                    emit SourceFiltered(oracleAddr, oraclePrice, uint64(oracleTimestamp), 2); // 2=deviant
                    continue;
                }

                prices[validCount] = oraclePrice;
                weights[validCount] = config.weight;
                timestamps[validCount] = uint64(oracleTimestamp);
                validCount++;
            } catch {
                // Oracle failed, skip
                emit SourceFiltered(oracleAddr, 0, 0, 3); // 3=failed
                continue;
            }
        }

        // SECURITY FIX: Require strict minimum quorum of valid sources
        if (validCount < minQuorum) {
            return (0, 0, LOW_QUORUM, validCount);
        }

        // SECURITY FIX: Additional check - ensure at least 51% of active oracles are valid
        if (validCount < (currentActiveCount + 1) / 2) {
            return (0, 0, LOW_QUORUM, validCount);
        }

        // Use weighted median with timestamp tracking
        uint64 medianTimestamp;
        (price, medianTimestamp) = _weightedMedianWithTs(prices, weights, timestamps, validCount);

        // Check if aggregate deviates too much from TWAP
        if (center != 0) {
            uint256 deviation = price > center
                ? ((price - center) * 10000) / center
                : ((center - price) * 10000) / center;

            if (deviation > maxDeviationFromTwapBps) {
                return (0, medianTimestamp, DEVIANT_VS_TWAP, validCount);
            }
        }

        // Check if data is too stale using configurable threshold
        if (aggregateMaxAge > 0 && block.timestamp - medianTimestamp > aggregateMaxAge) {
            flags |= STALE;
        }

        timestamp = medianTimestamp;
        return (price, timestamp, flags, validCount);
    }

    function canUpdate() external view returns (bool valid, uint8 reasonCode) {
        (uint256 price, uint256 timestamp, uint8 flags) = _getMedianPriceWithFlags();

        if (flags == OK && price > 0) {
            return (true, 0);
        }

        return (false, flags);
    }

    // For backward compatibility - more expensive due to strings
    function canUpdateWithReason() external view returns (bool valid, string memory reason) {
        (uint256 price, uint256 timestamp, uint8 flags) = _getMedianPriceWithFlags();

        if (flags == OK && price > 0) {
            return (true, "");
        }

        if (flags & LOW_QUORUM != 0) {
            return (false, "Insufficient oracle quorum");
        }
        if (flags & DEVIANT_VS_TWAP != 0) {
            return (false, "Price deviates too much from TWAP");
        }
        if (flags & STALE != 0) {
            return (false, "Oracle data too stale");
        }

        return (false, "Unknown error");
    }

    function getOracles() external view returns (address[] memory) {
        return oracleList;
    }

    function isOracleActive(address oracle) external view returns (bool) {
        return oracles[oracle].isActive;
    }

    function getActiveOracleCount() public view returns (uint256) {
        return activeCount;
    }

    /**
     * @notice Get current quorum status for security monitoring
     * @return currentActive Current number of active oracles
     * @return requiredQuorum Required minimum quorum
     * @return meetsQuorum Whether current active count meets quorum requirements
     * @return canRemove Whether it's safe to remove an oracle (wouldn't break quorum)
     */
    function getQuorumStatus() external view returns (
        uint256 currentActive,
        uint256 requiredQuorum,
        bool meetsQuorum,
        bool canRemove
    ) {
        currentActive = activeCount;
        requiredQuorum = minQuorum;
        meetsQuorum = currentActive >= minQuorum;
        canRemove = currentActive > minQuorum; // Can remove if we'd still have quorum
    }

    function _getMedianPrice() internal view returns (uint256 price, uint256 timestamp) {
        (price, timestamp,) = _getMedianPriceWithFlags();
    }

    function _getMedianPriceWithFlags() internal view returns (uint256 price, uint256 timestamp, uint8 flags) {
        (price, timestamp, flags,) = _getMedianPriceWithFlagsAndCount();
    }

    function _getMedianPriceWithFlagsAndCount() internal view returns (uint256 price, uint256 timestamp, uint8 flags, uint256 sourceCount) {
        uint256 currentActiveCount = getActiveOracleCount();

        // SECURITY FIX: Enforce strict minimum quorum requirements
        if (currentActiveCount < minQuorum) {
            return (0, 0, LOW_QUORUM, 0);
        }

        uint256[] memory prices = new uint256[](oracleList.length);
        uint256[] memory weights = new uint256[](oracleList.length);
        uint64[] memory timestamps = new uint64[](oracleList.length);
        uint256 validCount = 0;

        uint256 center = _center();


        for (uint256 i = 0; i < oracleList.length; i++) {
            address oracleAddr = oracleList[i];
            SourceConfig memory config = oracles[oracleAddr];
            if (!config.isActive) continue;

            try IOracle(oracleAddr).viewPrice() returns (uint256 oraclePrice, uint256 oracleTimestamp) {
                // Reject future timestamps explicitly
                if (oracleTimestamp > block.timestamp) {
                    continue;
                }

                // Use per-source staleness check
                if (_isStaleForSource(oracleTimestamp, config.maxAge)) {
                    continue;
                }

                // Use per-source deviation check
                if (_isOutlierForSource(oraclePrice, center, config.maxDeviationBps)) {
                    continue;
                }

                prices[validCount] = oraclePrice;
                weights[validCount] = config.weight;
                timestamps[validCount] = uint64(oracleTimestamp);
                validCount++;
            } catch {
                // Oracle failed, skip
                continue;
            }
        }

        // SECURITY FIX: Require strict minimum quorum of valid sources
        if (validCount < minQuorum) {
            return (0, 0, LOW_QUORUM, validCount);
        }

        // SECURITY FIX: Additional check - ensure at least 51% of active oracles are valid
        if (validCount < (currentActiveCount + 1) / 2) {
            return (0, 0, LOW_QUORUM, validCount);
        }

        // Use weighted median with timestamp tracking
        uint64 medianTimestamp;
        (price, medianTimestamp) = _weightedMedianWithTs(prices, weights, timestamps, validCount);

        // Check if aggregate deviates too much from TWAP
        if (center != 0) {
            uint256 deviation = price > center
                ? ((price - center) * 10000) / center
                : ((center - price) * 10000) / center;

            if (deviation > maxDeviationFromTwapBps) {
                return (0, medianTimestamp, DEVIANT_VS_TWAP, validCount);
            }
        }

        // Check if data is too stale using configurable threshold
        if (aggregateMaxAge > 0 && block.timestamp - medianTimestamp > aggregateMaxAge) {
            flags |= STALE;
        }

        timestamp = medianTimestamp;
        return (price, timestamp, flags, validCount);
    }


    function _weightedMedianWithTs(
        uint256[] memory prices,
        uint256[] memory weights,
        uint64[] memory ts,
        uint256 length
    ) internal pure returns (uint256, uint64) {
        require(length > 0, "Empty arrays");

        // Create array of indices for sorting
        uint256[] memory indices = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            indices[i] = i;
        }

        // Sort indices by price (insertion sort for small arrays)
        for (uint256 i = 1; i < length; i++) {
            uint256 j = i;
            uint256 keyIndex = indices[i];
            while (j > 0 && prices[indices[j-1]] > prices[keyIndex]) {
                indices[j] = indices[j-1];
                j--;
            }
            indices[j] = keyIndex;
        }

        // Calculate total weight
        uint256 weightSum = 0;
        for (uint256 i = 0; i < length; i++) {
            weightSum += weights[i];
        }
        require(weightSum > 0, "Zero total weight");

        // Find weighted median with unbiased cutoff
        uint256 cutoff = (weightSum + 1) / 2;
        uint256 cumulativeWeight = 0;

        for (uint256 i = 0; i < length; i++) {
            uint256 idx = indices[i];
            cumulativeWeight += weights[idx];
            if (cumulativeWeight >= cutoff) {
                return (prices[idx], ts[idx]);
            }
        }

        // Fallback to last price if something went wrong
        uint256 lastIdx = indices[length - 1];
        return (prices[lastIdx], ts[lastIdx]);
    }


    function _isStaleForSource(uint256 timestamp, uint256 maxAge) internal view returns (bool) {
        if (timestamp == 0) return true;
        if (timestamp > block.timestamp) return true; // Reject future timestamps
        return block.timestamp - timestamp > maxAge;
    }

    function _isOutlierForSource(uint256 price, uint256 center, uint256 maxDeviationBps) internal pure returns (bool) {
        if (center == 0 || maxDeviationBps == 0) return false;

        uint256 deviation = price > center
            ? ((price - center) * 10000) / center
            : ((center - price) * 10000) / center;

        return deviation > maxDeviationBps;
    }


    function _center() internal view returns (uint256) {
        // use short TWAP (30 min). If not enough points, last.
        uint256 twapPrice = _twap(30 minutes);
        return twapPrice != 0 ? twapPrice : (histLen > 0 ? priceHistory[histHead].priceX18 : 0);
    }

    function _addPricePoint(uint256 price, uint256 timestamp) internal {
        unchecked {
            histHead = uint16((histHead + 1) % HIST);
            priceHistory[histHead] = PricePoint(price, uint64(timestamp));
            if (histLen < HIST) histLen++;
        }
    }
}
