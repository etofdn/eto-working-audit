// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 * ██████╗ ███████╗ ██████╗     ███████╗████████╗ █████╗ ██████╗ ██╗██╗     ██╗████████╗██╗   ██╗    ███╗   ███╗ ██████╗ ██████╗ ██╗   ██╗██╗     ███████╗
 * ██╔══██╗██╔════╝██╔════╝     ██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██║██║     ██║╚══██╔══╝╚██╗ ██╔╝    ████╗ ████║██╔═══██╗██╔══██╗██║   ██║██║     ██╔════╝
 * ██████╔╝█████╗  ██║  ███╗    ███████╗   ██║   ███████║██████╔╝██║██║     ██║   ██║    ╚████╔╝     ██╔████╔██║██║   ██║██║  ██║██║   ██║██║     █████╗
 * ██╔═══╝ ██╔══╝  ██║   ██║    ╚════██║   ██║   ██╔══██║██╔══██╗██║██║     ██║   ██║     ╚██╔╝      ██║╚██╔╝██║██║   ██║██║  ██║██║   ██║██║     ██╔══╝
 * ██║     ███████╗╚██████╔╝    ███████║   ██║   ██║  ██║██████╔╝██║███████╗██║   ██║      ██║       ██║ ╚═╝ ██║╚██████╔╝██████╔╝╚██████╔╝███████╗███████╗
 * ╚═╝     ╚══════╝ ╚═════╝     ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═════╝ ╚═╝╚══════╝╚═╝   ╚═╝      ╚═╝       ╚═╝     ╚═╝ ╚═════╝ ╚═════╝  ╚═════╝ ╚══════╝╚══════╝
 *
 * Peg Stability Module (PSM) - Arbitrage-Driven Peg Mechanism
 *
 * The PSM maintains DRI's peg to $1 through a hybrid arbitrage mechanism that allows permissionless
 * trading between DRI and USDC while enforcing strict price boundaries and fee-driven rebalancing.
 */

import "../interfaces/IPSM.sol";
import "../interfaces/IDRIController.sol";
import "../interfaces/IDMM.sol";
import "../utils/FixedPointMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// Interface for mintable tokens
// CRITICAL FIX: Removed IMintable interface - DRI has fixed supply!
// No minting is allowed in the DRI protocol

contract PegStabilityModule is IPSM, Ownable, ReentrancyGuard {
    using FixedPointMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public immutable driToken;
    IERC20 public immutable usdcToken;
    IDRIController public driController;
    IDMM public immutable dmm;

    ArbConfig public arbConfig;
    ReserveState public reserveState;

    uint256 public lastArbTime;
    uint256 public totalFeesCollected;
    uint256 public seigniorageLimit; // μ - max seigniorage as % of total supply
    bool public isThrottled;

    // Security: Minting limits and cooldowns
    // CRITICAL FIX: Removed minting variables - DRI has fixed supply!
    // No minting is allowed in the DRI protocol

    uint256[] public deviationHistory;
    uint256 public constant MAX_DEVIATION_HISTORY = 10;

    /// @notice Per-provider accounting (no mint/burn, just custody credits)
    mapping(address => uint256) public maangOf;
    mapping(address => uint256) public usdcOf;

    // Only the controller may invoke arbitrage; users and even owner cannot directly call
    modifier onlyController() {
        require(msg.sender == address(driController), "Not authorized");
        _;
    }

    constructor(address _driToken, address _usdcToken, address _driController, address _dmm, address _owner)
        Ownable(_owner)
    {
        require(_driToken != address(0), "Invalid DRI token");
        require(_usdcToken != address(0), "Invalid USDC token");
        require(_driController != address(0), "Invalid controller");
        require(_dmm != address(0), "Invalid DMM");

        driToken = IERC20(_driToken);
        usdcToken = IERC20(_usdcToken);
        driController = IDRIController(_driController);
        dmm = IDMM(_dmm);
        controllerSet = true; // Controller fixed at deployment to prevent initialization race

        // Default arbitrage configuration
        arbConfig = ArbConfig({
            swapCap: 0.003e18, // 0.30% of pool TVL
            maxUsdcDraw: 0.2e18, // 20% of USDC reserve
            reserveFloor: 0.3e18, // 30% of launch reserve
            deviationThreshold: 0.005e18, // 0.5% deviation threshold
            feeRate: 0.001e18 // 0.1% fee surcharge
        });

        seigniorageLimit = 0.05e18; // 5% of total supply
    }

    bool public controllerSet;

    function setController(address /*_controller*/ ) external pure {
        revert("Controller immutable");
    }

    function fundReserve(uint256 driAmount, uint256 usdcAmount) external nonReentrant {
        require(driAmount > 0 || usdcAmount > 0, "Amounts must be positive");

        // Transfer tokens to reserve
        if (driAmount > 0) {
            IERC20(address(driToken)).safeTransferFrom(msg.sender, address(this), driAmount);
            maangOf[msg.sender] += driAmount;
        }
        if (usdcAmount > 0) {
            usdcToken.safeTransferFrom(msg.sender, address(this), usdcAmount);
            usdcOf[msg.sender] += usdcAmount;
        }

        // Update reserve state
        reserveState.driTokens += driAmount;
        reserveState.usdcTokens += usdcAmount;
        _updateReserveMetrics();

        emit ReserveVaultFunded(driAmount, usdcAmount);
    }

    /**
     * @notice Withdraw provider's MAANG/USDC from PSM reserves
     * @param driAmount Amount of MAANG to withdraw
     * @param usdcAmount Amount of USDC to withdraw
     */
    function withdrawReserve(uint256 driAmount, uint256 usdcAmount) external nonReentrant {
        require(driAmount > 0 || usdcAmount > 0, "Amounts must be positive");

        if (driAmount > 0) {
            require(maangOf[msg.sender] >= driAmount, "Insufficient MAANG credit");
            maangOf[msg.sender] -= driAmount;
            IERC20(address(driToken)).safeTransfer(msg.sender, driAmount);
        }
        if (usdcAmount > 0) {
            require(usdcOf[msg.sender] >= usdcAmount, "Insufficient USDC credit");
            usdcOf[msg.sender] -= usdcAmount;
            usdcToken.safeTransfer(msg.sender, usdcAmount);
        }

        // Update reserve state
        reserveState.driTokens -= driAmount;
        reserveState.usdcTokens -= usdcAmount;
        _updateReserveMetrics();
    }

    function executeArbSwap(bool isBuy, uint256 maxAmount)
        external
        onlyController
        nonReentrant
        returns (uint256 amountOut)
    {
        (bool canArb, uint256 deviation) = canExecuteArb();
        require(canArb, "Arbitrage conditions not met");
        require(!isThrottled, "PSM is throttled");

        // SECURITY: Check minimum reserve levels before arbitrage
        uint256 initialReserve = _getInitialReserve();
        uint256 minReserve = initialReserve.mul(0.1e18); // 10% minimum reserve
        require(reserveState.usdcTokens >= minReserve, "Reserves too low for arbitrage");

        uint256 swapSize = estimateArbSize(isBuy);
        require(swapSize > 0, "No arbitrage opportunity");

        // SECURITY: Limit swap size to prevent excessive draining
        uint256 maxSwapSize = reserveState.usdcTokens.mul(arbConfig.maxUsdcDraw);
        swapSize = FixedPointMath.min(swapSize, maxSwapSize);

        if (maxAmount > 0) {
            swapSize = FixedPointMath.min(swapSize, maxAmount);
        }

        if (isBuy) {
            // Buy DRI with USDC (market price < reflective price)
            require(reserveState.usdcTokens >= swapSize, "Insufficient USDC reserve");

            // Execute swap through DMM
            usdcToken.approve(address(dmm), swapSize);
            amountOut = dmm.swap(address(usdcToken), swapSize, 0);

            // Update reserves
            reserveState.usdcTokens -= swapSize;
            reserveState.driTokens += amountOut;
        } else {
            // Sell DRI for USDC (market price > reflective price)
            require(reserveState.driTokens >= swapSize, "Insufficient DRI reserve");

            // Execute swap through DMM
            driToken.approve(address(dmm), swapSize);
            amountOut = dmm.swap(address(driToken), swapSize, 0);

            // Update reserves
            reserveState.driTokens -= swapSize;
            reserveState.usdcTokens += amountOut;
        }

        _updateReserveMetrics();
        _trackDeviation(deviation);
        _checkThrottling();

        lastArbTime = block.timestamp;

        emit ArbSwapExecuted(isBuy, swapSize, amountOut, dmm.getCurrentPrice());
    }

    function replenishReserve() external onlyOwner nonReentrant returns (uint256 usdcRaised) {
        require(
            reserveState.usdcTokens < _getInitialReserve().mul(arbConfig.reserveFloor), "Reserve above floor threshold"
        );

        uint256 targetReplenish = _getInitialReserve().mul(arbConfig.reserveFloor) - reserveState.usdcTokens;
        uint256 currentPrice = driController.getReflectivePrice();

        /// @dev DRI is fixed-supply; replenishment uses existing DRI held by PSM

        // Check if we have DRI tokens available for sale
        uint256 driBalance = driToken.balanceOf(address(this));
        require(driBalance > 0, "No DRI tokens available for reserve replenishment");

        // Calculate how much DRI we can sell to reach target
        uint256 driToSell = Math.min(driBalance, targetReplenish.div(currentPrice));
        require(driToSell > 0, "Insufficient DRI to sell");

        // Sell existing DRI for USDC
        driToken.approve(address(dmm), driToSell);
        usdcRaised = dmm.swap(address(driToken), driToSell, 0);

        reserveState.usdcTokens += usdcRaised;
        _updateReserveMetrics();

        emit ReserveReplenished(usdcRaised, driToSell);
    }

    function canExecuteArb() public view returns (bool, uint256) {
        uint256 marketPrice = dmm.getCurrentPrice();
        uint256 reflectivePrice = driController.getReflectivePrice();

        if (marketPrice == 0 || reflectivePrice == 0) return (false, 0);

        uint256 deviation = marketPrice > reflectivePrice
            ? ((marketPrice - reflectivePrice) * FixedPointMath.SCALE) / reflectivePrice
            : ((reflectivePrice - marketPrice) * FixedPointMath.SCALE) / reflectivePrice;

        // PSM only arbitrages when deviation is under 70 bps (controller handles anything larger)
        uint256 deviationBps = (deviation * 10000) / FixedPointMath.SCALE;
        bool meetsThreshold = deviationBps < 70; // strictly under 70 bps

        // Check circuit breaker status
        (bool isCircuitBreakerActive,) = driController.isCircuitBreakerActive();
        bool systemOperational = !isCircuitBreakerActive;

        return (meetsThreshold && systemOperational, deviation);
    }

    function estimateArbSize(bool isBuy) public view returns (uint256) {
        uint256 marketPrice = dmm.getCurrentPrice();
        uint256 reflectivePrice = driController.getReflectivePrice();

        if (marketPrice == 0 || reflectivePrice == 0) return 0;

        // Get DMM TVL for swap cap calculation
        IDMM.LiquidityPosition memory position = dmm.getLiquidityPosition();
        uint256 poolTVL = position.driTokens.mul(marketPrice) + position.usdcTokens;

        // Calculate max swap based on TVL cap
        uint256 maxByTVL = poolTVL.mul(arbConfig.swapCap);

        if (isBuy) {
            // Buying DRI with USDC - limited by USDC reserve
            uint256 maxByReserve = reserveState.usdcTokens.mul(arbConfig.maxUsdcDraw);
            return FixedPointMath.min(maxByTVL, maxByReserve);
        } else {
            // Selling DRI for USDC - limited by DRI reserve
            // Convert DRI reserve to USDC equivalent using current market price
            uint256 driValueInUsdc = reserveState.driTokens.mul(marketPrice) / 1e18;
            uint256 maxByReserve = driValueInUsdc.mul(arbConfig.maxUsdcDraw);
            return FixedPointMath.min(maxByTVL, maxByReserve);
        }
    }

    function getReserveState() external view returns (ReserveState memory) {
        return reserveState;
    }

    function getArbConfig() external view returns (ArbConfig memory) {
        return arbConfig;
    }

    // Security: Getter functions for minting limits
    // CRITICAL FIX: Removed getMintingStatus function - DRI has fixed supply!
    // No minting is allowed in the DRI protocol

    function updateArbConfig(ArbConfig calldata _config) external onlyOwner {
        require(_config.swapCap <= 0.05e18, "Swap cap too high"); // Max 5% (increased for $15M TVL)
        require(_config.maxUsdcDraw <= 0.5e18, "USDC draw too high"); // Max 50% (increased for $15M TVL)
        require(_config.reserveFloor >= 0.1e18, "Reserve floor too low"); // Min 10%
        require(_config.deviationThreshold <= 0.03e18, "Threshold too high"); // Max 3% (increased for $15M TVL)

        arbConfig = _config;
        emit PSMConfigUpdated(_config);
    }

    function setSeigniorageLimit(uint256 _limit) external onlyOwner {
        require(_limit <= 0.3e18, "Seigniorage limit too high"); // Max 30% (increased for $15M TVL)
        seigniorageLimit = _limit;
    }

    function emergencyPause() external onlyOwner {
        isThrottled = true;
    }

    function unpause() external onlyOwner {
        isThrottled = false;
    }

    function _updateReserveMetrics() internal {
        uint256 currentPrice = driController.getReflectivePrice();
        reserveState.totalValue = reserveState.driTokens.mul(currentPrice) + reserveState.usdcTokens;

        uint256 initialValue = _getInitialReserve().mul(2); // Initial value (DRI + USDC)
        reserveState.utilizationRate =
            initialValue > 0 ? (initialValue - reserveState.totalValue).fraction(initialValue) : 0;
    }

    function _trackDeviation(uint256 deviation) internal {
        deviationHistory.push(deviation);

        if (deviationHistory.length > MAX_DEVIATION_HISTORY) {
            // Shift array left
            for (uint256 i = 0; i < deviationHistory.length - 1; i++) {
                deviationHistory[i] = deviationHistory[i + 1];
            }
            deviationHistory.pop();
        }
    }

    function _checkThrottling() internal {
        // SECURITY: Re-enable throttling to prevent reserve drainage
        uint256 initialReserve = _getInitialReserve();
        bool belowFloor = reserveState.usdcTokens < initialReserve.mul(arbConfig.reserveFloor);

        if (belowFloor && !isThrottled) {
            isThrottled = true;
            // Reduce swap capacity when reserves are low
            arbConfig.deviationThreshold = arbConfig.deviationThreshold.mul(2);
            arbConfig.swapCap = arbConfig.swapCap / 2;
            emit DrawdownThrottled(arbConfig.deviationThreshold, arbConfig.swapCap);
        } else if (!belowFloor && isThrottled) {
            // Re-enable normal operation when reserves recover
            isThrottled = false;
            // Reset parameters to normal levels
            arbConfig.deviationThreshold = arbConfig.deviationThreshold / 2;
            arbConfig.swapCap = arbConfig.swapCap * 2;
        }
    }

    function _getInitialReserve() internal pure returns (uint256) {
        // This should be set during initialization based on launch parameters
        // For now, return a placeholder
        return 1000000e6; // 1M USDC placeholder
    }

    function collectFees() external onlyOwner {
        uint256 fees = totalFeesCollected;
        totalFeesCollected = 0;

        if (fees > 0) {
            usdcToken.safeTransfer(owner(), fees);
        }
    }

    function getMaxRecentDeviation() external view returns (uint256) {
        uint256 max = 0;
        for (uint256 i = 0; i < deviationHistory.length; i++) {
            if (deviationHistory[i] > max) {
                max = deviationHistory[i];
            }
        }
        return max;
    }
}
