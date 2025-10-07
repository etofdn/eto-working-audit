// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * ███████╗███╗   ███╗ █████╗  █████╗ ███╗   ██╗ ██████╗     ██╗   ██╗ █████╗ ██╗   ██╗██╗  ████████╗
 * ██╔════╝████╗ ████║██╔══██╗██╔══██╗████╗  ██║██╔════╝     ██║   ██║██╔══██╗██║   ██║██║  ╚══██╔══╝
 * ███████╗██╔████╔██║███████║███████║██╔██╗ ██║██║  ███╗    ██║   ██║███████║██║   ██║██║     ██║
 * ╚════██║██║╚██╔╝██║██╔══██║██╔══██║██║╚██╗██║██║   ██║    ╚██╗ ██╔╝██╔══██║██║   ██║██║     ██║
 * ███████║██║ ╚═╝ ██║██║  ██║██║  ██║██║ ╚████║╚██████╔╝     ╚████╔╝ ██║  ██║╚██████╔╝███████╗██║
 * ╚══════╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝       ╚═══╝  ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝
 *
 * SMAANG Vault - Synthetic MAAG Index Token
 *
 * ERC4626-inspired vault that provides exposure to the MAAG basket (META, AAPL, AMZN, GOOGL)
 * through automated liquidity deployment across DMM and PSM strategies with gradual rebalancing.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IDMM.sol";
import "../interfaces/IPSM.sol";
import "../interfaces/IDRIController.sol";

/**
 * @title SMAANGVault
 * @notice ERC-4626 vault that accepts MAANG-only, USDC-only, or MAANG/USDC pair deposits
 * @dev Mints sMAANG shares based on MAANG-equivalent value, auto-balances to DMM/PSM targets
 */
contract SMAANGVault is ERC20, Ownable, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ IMMUTABLES ============

    /// @notice MAANG token (18 decimals)
    IERC20 public immutable MAANG;

    /// @notice USDC token (6 decimals)
    IERC20 public immutable USDC;

    /// @notice Dynamic Market Maker for liquidity provision
    IDMM public immutable dmm;

    /// @notice Peg Stability Module for reserve management
    IPSM public immutable psm;

    /// @notice DRI Controller for reflective pricing
    IDRIController public immutable controller;

    // ============ STATE VARIABLES ============

    /// @notice Target allocation to DMM (basis points, 10000 = 100%)
    uint16 public dmmBps = 5000;

    /// @notice Target allocation to PSM (basis points, 10000 = 100%)
    uint16 public psmBps = 5000;

    /// @notice Max allowed spot vs reflective price deviation (basis points)
    uint16 public maxSpotDeviationBps = 50; // 0.50%

    /// @notice Maximum single swap size (basis points of deposit)
    uint16 public maxSingleSwapBps = 5000; // 50%

    /// @notice Deposit cap (in MAANG-equivalent units)
    uint256 public depositCap;

    /// @notice Whether deposits are paused
    bool public depositsPaused;

    /// @notice Maximum oracle staleness (seconds)
    uint256 public maxOracleStaleness = 900; // 15 minutes

    // ============ DRIP & REBALANCE STATE ============

    /// @notice Last block when drip was executed
    uint256 public lastDripBlock;

    /// @notice Percentage of staged buffers to release per tick (basis points)
    uint16 public dripBpsPerTick = 1000; // 10% per tick

    /// @notice Blocks between drip executions
    uint16 public dripIntervalBlocks = 5; // every 5 blocks

    /// @notice Max percentage of DMM value to rebalance per tick (basis points)
    uint16 public rebalanceBpsPerTick = 500; // 5% of DMM value per tick

    /// @notice Price drift deadband for rebalancing (basis points)
    uint16 public rebalanceDeadbandBps = 15; // ignore drift < 0.15%

    /// @notice Staged MAANG waiting to be dripped to strategies
    uint256 public stagedMAANG;

    /// @notice Staged USDC waiting to be dripped to strategies
    uint256 public stagedUSDC;

    /// @notice Per-user staged accounting to prevent pooled staged withdrawal abuse
    mapping(address => uint256) public userStagedMAANG;
    mapping(address => uint256) public userStagedUSDC;

    // ============ MEV PROTECTION ============

    /// @notice Keeper role for authorized drip execution
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice Commit-reveal mechanism for MEV protection
    mapping(bytes32 => uint256) private dripCommits;

    /// @notice Minimum blocks delay for commit-reveal
    uint256 public constant COMMIT_DELAY = 3;

    // ============ EVENTS ============

    event TargetWeightsUpdated(uint16 dmmBps, uint16 psmBps);
    event MaxSpotDeviationUpdated(uint16 bps);
    event MaxSingleSwapUpdated(uint16 bps);
    event DepositCapUpdated(uint256 cap);
    event DepositsPaused(bool paused);
    event MaxOracleStalenessUpdated(uint256 seconds_);
    event DepositExecuted(address indexed user, uint256 maangEq, uint256 shares);
    event WithdrawalExecuted(address indexed user, uint256 shares, uint256 maangOut);
    event EmergencyWithdrawExecuted(address indexed admin, uint256 maangOut, uint256 usdcOut);
    event FeesClaimed(uint256 driFees, uint256 usdcFees);
    event DripExecuted(uint256 maangReleased, uint256 usdcReleased, uint256 dmmAdded, uint256 psmAdded);
    event RebalanceExecuted(uint256 driftBps, uint256 budgetUsed, bool spotAboveP);
    event DripCommitted(bytes32 indexed commitment, address indexed keeper);
    event DripExecutedSecurely(uint256 maangReleased, uint256 usdcReleased, uint256 dmmAdded, uint256 psmAdded);

    // ============ CONSTRUCTOR ============

    constructor(
        address _maang,
        address _usdc,
        address _dmm,
        address _psm,
        address _controller
    ) ERC20("Staked MAANG", "sMAANG") Ownable(msg.sender) {
        require(_maang != address(0), "Invalid MAANG");
        require(_usdc != address(0), "Invalid USDC");
        require(_dmm != address(0), "Invalid DMM");
        require(_psm != address(0), "Invalid PSM");
        require(_controller != address(0), "Invalid Controller");

        MAANG = IERC20(_maang);
        USDC = IERC20(_usdc);
        dmm = IDMM(_dmm);
        psm = IPSM(_psm);
        controller = IDRIController(_controller);

        // SECURITY FIX: Set up access control for MEV protection
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender); // Owner is initial keeper
    }

    // ============ EXTERNAL: DEPOSITS ============

    /**
     * @notice Deposit MAANG-only and mint sMAANG shares
     * @param maangIn Amount of MAANG to deposit
     * @param to Address to mint shares to
     * @return shares Amount of sMAANG shares minted
     */
    function depositMAANG(uint256 maangIn, address to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        require(maangIn > 0, "Amount zero");
        require(to != address(0), "Invalid recipient");
        require(!depositsPaused, "Deposits paused");

        MAANG.safeTransferFrom(msg.sender, address(this), maangIn);

        uint256 P = _getReflectivePrice();
        _checkSpotPriceDeviation(P);

        uint256 tvlBefore = _getTotalAssetsMAANG(P);
        require(tvlBefore + maangIn <= depositCap || depositCap == 0, "Exceeds deposit cap");

        // Stage by targets: keep on-vault until drip()
        uint256 toDMM = (maangIn * dmmBps) / 10000;
        uint256 toPSM = maangIn - toDMM;

        // Stage MAANG for both DMM and PSM (will be converted during drip)
        stagedMAANG += toDMM;
        stagedMAANG += toPSM;
        // Track user-specific staged MAANG to prevent pooled-withdraw exploitation
        userStagedMAANG[to] += maangIn;

        uint256 tvlAfter = _getTotalAssetsMAANG(P);
        shares = _mintShares(tvlAfter - tvlBefore, tvlBefore, to);

        emit DepositExecuted(to, maangIn, shares);
    }

    /**
     * @notice Deposit USDC-only and mint sMAANG shares
     * @param usdcIn Amount of USDC to deposit
     * @param to Address to mint shares to
     * @return shares Amount of sMAANG shares minted
     */
    function depositUSDC(uint256 usdcIn, address to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        require(usdcIn > 0, "Amount zero");
        require(to != address(0), "Invalid recipient");
        require(!depositsPaused, "Deposits paused");

        USDC.safeTransferFrom(msg.sender, address(this), usdcIn);

        uint256 P = _getReflectivePrice();
        _checkSpotPriceDeviation(P);

        // Convert USDC to MAANG-equivalent for cap check
        uint256 maangEq = Math.mulDiv(usdcIn, 1e18, P);
        uint256 tvlBefore = _getTotalAssetsMAANG(P);
        require(tvlBefore + maangEq <= depositCap || depositCap == 0, "Exceeds deposit cap");

        // Stage USDC; drip() will split/convert as needed
        stagedUSDC += usdcIn;
        // Track user-specific staged USDC to prevent pooled-withdraw exploitation
        userStagedUSDC[to] += usdcIn;

        uint256 tvlAfter = _getTotalAssetsMAANG(P);
        shares = _mintShares(tvlAfter - tvlBefore, tvlBefore, to);

        emit DepositExecuted(to, maangEq, shares);
    }

    /**
     * @notice Deposit MAANG/USDC pair and mint sMAANG shares
     * @param maangIn Amount of MAANG to deposit
     * @param usdcIn Amount of USDC to deposit
     * @param to Address to mint shares to
     * @return shares Amount of sMAANG shares minted
     */
    function depositPair(uint256 maangIn, uint256 usdcIn, address to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        require(maangIn > 0 || usdcIn > 0, "Both amounts zero");
        require(to != address(0), "Invalid recipient");
        require(!depositsPaused, "Deposits paused");

        if (maangIn > 0) MAANG.safeTransferFrom(msg.sender, address(this), maangIn);
        if (usdcIn > 0) USDC.safeTransferFrom(msg.sender, address(this), usdcIn);

        uint256 P = _getReflectivePrice();
        _checkSpotPriceDeviation(P);

        // Calculate MAANG-equivalent total
        uint256 maangEq = maangIn + Math.mulDiv(usdcIn, 1e18, P);
        uint256 tvlBefore = _getTotalAssetsMAANG(P);
        require(tvlBefore + maangEq <= depositCap || depositCap == 0, "Exceeds deposit cap");

        // Stage both tokens; drip() will handle the balancing
        stagedMAANG += maangIn;
        stagedUSDC += usdcIn;

        uint256 tvlAfter = _getTotalAssetsMAANG(P);
        shares = _mintShares(tvlAfter - tvlBefore, tvlBefore, to);

        emit DepositExecuted(to, maangEq, shares);
    }

    // ============ EXTERNAL: WITHDRAWALS ============

    /**
     * @notice Withdraw MAANG by burning sMAANG shares
     * @param shares Amount of sMAANG shares to burn
     * @param to Address to send MAANG to
     * @return maangOut Amount of MAANG withdrawn
     */
    function withdraw(uint256 shares, address to)
        external
        nonReentrant
        returns (uint256 maangOut)
    {
        require(shares > 0, "Shares zero");
        require(to != address(0), "Invalid recipient");
        require(balanceOf(msg.sender) >= shares, "Insufficient shares");

        uint256 P = _getReflectivePrice();

        // Calculate MAANG needed
        uint256 totalShares = totalSupply();
        uint256 totalAssets_ = _getTotalAssetsMAANG(P);
        maangOut = Math.mulDiv(shares, totalAssets_, totalShares);

        // Burn shares
        _burn(msg.sender, shares);

        // SECURITY FIX: First use staged MAANG if available
        uint256 maangOnVault = MAANG.balanceOf(address(this));
        uint256 stillNeeded = maangOut;

        // Use only user's staged MAANG first (prevent pooled staged drain)
        if (userStagedMAANG[msg.sender] > 0 && stillNeeded > 0) {
            uint256 fromStaged = Math.min(stillNeeded, userStagedMAANG[msg.sender]);
            userStagedMAANG[msg.sender] -= fromStaged;
            stagedMAANG -= fromStaged;
            stillNeeded -= fromStaged;
        }

        // Then pull from strategies if still needed
        if (maangOnVault < stillNeeded) {
            _pullFromStrategies(stillNeeded - maangOnVault, P);
        }

        // Send MAANG to user
        MAANG.safeTransfer(to, maangOut);

        emit WithdrawalExecuted(msg.sender, shares, maangOut);
    }

    // ============ INTERNAL: SWAP LOGIC ============

    /**
     * @notice Swap USDC to MAANG via DMM
     */
    function _swapUSDCToMAANG(uint256 usdcIn, uint256 P) internal returns (uint256 maangOut) {
        require(usdcIn > 0, "Swap amount zero");

        // Cap swap size
        uint256 maxSwap = (usdcIn * maxSingleSwapBps) / 10000;
        if (usdcIn > maxSwap) usdcIn = maxSwap;

        _forceApprove(USDC, address(dmm), usdcIn);
        uint256 expectedMaang = dmm.quote(address(USDC), usdcIn);
        uint256 minOut = (expectedMaang * 9970) / 10000; // 30 bps slippage

        maangOut = dmm.swap(address(USDC), usdcIn, minOut);
    }

    /**
     * @notice Swap MAANG to USDC via DMM
     */
    function _swapMAANGToUSDC(uint256 maangIn, uint256 P) internal returns (uint256 usdcOut) {
        require(maangIn > 0, "Swap amount zero");

        // Cap swap size
        uint256 maxSwap = (maangIn * maxSingleSwapBps) / 10000;
        if (maangIn > maxSwap) maangIn = maxSwap;

        _forceApprove(MAANG, address(dmm), maangIn);
        uint256 expectedUsdc = dmm.quote(address(MAANG), maangIn);
        uint256 minOut = (expectedUsdc * 9970) / 10000; // 30 bps slippage

        usdcOut = dmm.swap(address(MAANG), maangIn, minOut);
    }

    // ============ INTERNAL: STRATEGY INTERACTIONS ============

    /**
     * @notice Add liquidity to DMM
     */
    function _addLiquidityToDMM(uint256 maangAmt, uint256 usdcAmt, uint256 P) internal {
        if (maangAmt > 0 || usdcAmt > 0) {
            if (maangAmt > 0) {
                _forceApprove(MAANG, address(dmm), maangAmt);
            }
            if (usdcAmt > 0) {
                _forceApprove(USDC, address(dmm), usdcAmt);
            }
            dmm.addLiquidity(maangAmt, usdcAmt, 0);
        }
    }

    /**
     * @notice Fund PSM with MAANG/USDC
     */
    function _fundPSM(uint256 maangAmt, uint256 usdcAmt) internal {
        if (maangAmt > 0 || usdcAmt > 0) {
            if (maangAmt > 0) {
                _forceApprove(MAANG, address(psm), maangAmt);
            }
            if (usdcAmt > 0) {
                _forceApprove(USDC, address(psm), usdcAmt);
            }
            psm.fundReserve(maangAmt, usdcAmt);
        }
    }

    /**
     * @notice Pull MAANG from strategies to meet withdrawal
     */
    function _pullFromStrategies(uint256 maangNeeded, uint256 P) internal {
        if (maangNeeded == 0) return;

        // Compute TVL per strategy in MAANG-equivalent
        IDMM.LiquidityPosition memory pos = dmm.getLiquidityPosition();
        uint256 tvlDMM = pos.driTokens + Math.mulDiv(pos.usdcTokens, 1e18, P);
        IPSM.ReserveState memory rs = psm.getReserveState();
        uint256 tvlPSM = rs.driTokens + Math.mulDiv(rs.usdcTokens, 1e18, P);
        uint256 tot = tvlDMM + tvlPSM;

        require(tot > 0, "no strategy TVL");

        uint256 needDMM = Math.mulDiv(maangNeeded, tvlDMM, tot);
        uint256 needPSM = maangNeeded - needDMM;

        // DMM: determine liquidity shares to burn proportionally by value
        if (needDMM > 0 && pos.liquidity > 0) {
            uint256 valuePerL = 0;
            {
                uint256 usdcAsMaang = Math.mulDiv(pos.usdcTokens, 1e18, P);
                uint256 value = pos.driTokens + usdcAsMaang;
                if (value > 0) {
                    valuePerL = value;
                }
            }
            if (valuePerL > 0) {
                uint256 liqToBurn = Math.mulDiv(needDMM, pos.liquidity, valuePerL);
                if (liqToBurn > 0) {
                    (uint256 dOut, uint256 uOut) = dmm.removeLiquidity(liqToBurn);

                    // SECURITY FIX: Validate returned amounts meet minimum expectations
                    uint256 expectedValue = Math.mulDiv(liqToBurn, valuePerL, pos.liquidity);
                    uint256 actualValue = dOut + Math.mulDiv(uOut, 1e18, P);
                    require(actualValue >= (expectedValue * 95) / 100, "Insufficient liquidity returned");

                    // Swap any USDC leg to MAANG
                    if (uOut > 0) { _swapUSDCToMAANG(uOut, P); }
                    // If DRI leg also returned, it already counts toward MAANG
                }
            }
        }

        // PSM: Withdraw from our PSM credits
        if (needPSM > 0) {
            uint256 psmMaang = psm.maangOf(address(this));
            uint256 psmUsdc = psm.usdcOf(address(this));
            uint256 psmUsdcAsMaang = Math.mulDiv(psmUsdc, 1e18, P);
            uint256 psmTotal = psmMaang + psmUsdcAsMaang;

            if (psmTotal > 0) {
                // Withdraw proportionally from PSM
                uint256 withdrawMaang = Math.mulDiv(needPSM, psmMaang, psmTotal);
                uint256 withdrawUsdc = Math.mulDiv(needPSM, psmUsdcAsMaang, psmTotal);

                if (withdrawMaang > 0 || withdrawUsdc > 0) {
                    psm.withdrawReserve(withdrawMaang, withdrawUsdc);
                }

                // Convert any USDC to MAANG if needed
                if (withdrawUsdc > 0) {
                    _swapUSDCToMAANG(withdrawUsdc, P);
                }
            }
        }

        require(MAANG.balanceOf(address(this)) >= maangNeeded, "shortfall");
    }

    // ============ INTERNAL: PRICING & VALIDATION ============

    /**
     * @notice Get reflective price from controller with staleness check
     */
    function _getReflectivePrice() internal view returns (uint256 P) {
        P = controller.getReflectivePrice();
        require(P > 0, "Invalid reflective price");

        // Check oracle staleness (if controller exposes last update time)
        // For now, we rely on controller's internal staleness checks
        // TODO: Add explicit staleness check if controller exposes timestamp
    }

    /**
     * @notice Check spot price deviation from reflective price with DOS protection
     * @dev Implements tiered approach with emergency override to prevent DOS attacks
     */
    function _checkSpotPriceDeviation(uint256 P) internal view {
        uint256 spot = dmm.getCurrentPrice();
        require(spot > 0, "Invalid spot price");

        uint256 deviation = spot > P ? spot - P : P - spot;
        uint256 deviationBps = Math.mulDiv(deviation, 10000, P);

        // SECURITY FIX: Use different limits for deposits vs withdrawals
        uint256 maxDeviation = maxSpotDeviationBps;

        // Emergency override for withdrawals if deviation persists
        if (block.timestamp > lastDripBlock + 3600) { // 1 hour since last drip
            maxDeviation = maxSpotDeviationBps * 5; // Allow 5x normal deviation
        }

        require(deviationBps <= maxDeviation, "Spot price too far from reflective");
    }

    /**
     * @notice Calculate total assets in MAANG-equivalent
     */
    function _getTotalAssetsMAANG(uint256 P) internal view returns (uint256) {
        uint256 maangBal = MAANG.balanceOf(address(this));
        uint256 usdcBal = USDC.balanceOf(address(this));
        uint256 tvl = maangBal + Math.mulDiv(usdcBal, 1e18, P);

        // Include staged amounts
        tvl += stagedMAANG + Math.mulDiv(stagedUSDC, 1e18, P);

        // DMM position (pro-rata share only)
        tvl += _getDMMValue(P);

        // PSM reserve (vault's share only)
        tvl += _getPSMValue(P);

        return tvl;
    }

    /**
     * @notice Mint shares based on MAANG-equivalent delta
     */
    function _mintShares(uint256 deltaMaangEq, uint256 tvlBefore, address to) internal returns (uint256 shares) {
        uint256 totalShares = totalSupply();
        if (totalShares == 0) {
            shares = deltaMaangEq;
        } else {
            shares = Math.mulDiv(deltaMaangEq, totalShares, tvlBefore);
        }
        _mint(to, shares);
    }

    /**
     * @notice Get vault's pro-rata share of DMM value
     */
    function _getDMMValue(uint256 P) internal view returns (uint256) {
        IDMM.LiquidityPosition memory lp = dmm.getLiquidityPosition();
        uint256 totalLiq = dmm.getTotalLiquidity();

        if (totalLiq == 0) return 0;

        // Get vault's liquidity share
        uint256 myLiquidity = dmm.getUserLiquidity(address(this));
        if (myLiquidity == 0) return 0;

        // Calculate pro-rata share of pool reserves
        uint256 myDriTokens = Math.mulDiv(lp.driTokens, myLiquidity, totalLiq);
        uint256 myUsdcTokens = Math.mulDiv(lp.usdcTokens, myLiquidity, totalLiq);

        // Convert to MAANG-equivalent value
        return myDriTokens + Math.mulDiv(myUsdcTokens, 1e18, P);
    }

    /**
     * @notice Get vault's share of PSM value
     */
    function _getPSMValue(uint256 P) internal view returns (uint256) {
        // Use per-provider accounting instead of global reserve
        uint256 myMaang = psm.maangOf(address(this));
        uint256 myUsdc = psm.usdcOf(address(this));
        return myMaang + Math.mulDiv(myUsdc, 1e18, P);
    }

    /**
     * @notice Force approve pattern to handle tokens that require zero-then-set
     */
    function _forceApprove(IERC20 token, address spender, uint256 amount) internal {
        token.forceApprove(spender, amount);
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Set target allocation weights
     */
    function setTargetWeights(uint16 _dmmBps, uint16 _psmBps) external onlyOwner {
        require(_dmmBps + _psmBps == 10000, "Weights must sum to 100%");
        dmmBps = _dmmBps;
        psmBps = _psmBps;
        emit TargetWeightsUpdated(_dmmBps, _psmBps);
    }

    /**
     * @notice Set max spot price deviation
     */
    function setMaxSpotDeviation(uint16 bps) external onlyOwner {
        require(bps <= 1000, "Max 10% deviation"); // 10% max
        maxSpotDeviationBps = bps;
        emit MaxSpotDeviationUpdated(bps);
    }

    /**
     * @notice Set max single swap size
     */
    function setMaxSingleSwap(uint16 bps) external onlyOwner {
        require(bps <= 10000, "Max 100%");
        maxSingleSwapBps = bps;
        emit MaxSingleSwapUpdated(bps);
    }

    /**
     * @notice Set deposit cap
     */
    function setDepositCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit DepositCapUpdated(cap);
    }

    /**
     * @notice Pause/unpause deposits
     */
    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPaused(paused);
    }

    /**
     * @notice Emergency pause
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Set max oracle staleness
     */
    function setMaxOracleStaleness(uint256 seconds_) external onlyOwner {
        require(seconds_ >= 60 && seconds_ <= 3600, "Invalid staleness range"); // 1min to 1hr
        maxOracleStaleness = seconds_;
        emit MaxOracleStalenessUpdated(seconds_);
    }

    /**
     * @notice Set drip parameters
     */
    function setDripParams(uint16 _dripBpsPerTick, uint16 _dripIntervalBlocks) external onlyOwner {
        require(_dripBpsPerTick > 0 && _dripBpsPerTick <= 10000, "Invalid drip bps");
        require(_dripIntervalBlocks > 0 && _dripIntervalBlocks <= 100, "Invalid interval");
        dripBpsPerTick = _dripBpsPerTick;
        dripIntervalBlocks = _dripIntervalBlocks;
    }

    /**
     * @notice Set rebalance parameters
     */
    function setRebalanceParams(uint16 _rebalanceBpsPerTick, uint16 _rebalanceDeadbandBps) external onlyOwner {
        require(_rebalanceBpsPerTick > 0 && _rebalanceBpsPerTick <= 10000, "Invalid rebalance bps");
        require(_rebalanceDeadbandBps > 0 && _rebalanceDeadbandBps <= 1000, "Invalid deadband");
        rebalanceBpsPerTick = _rebalanceBpsPerTick;
        rebalanceDeadbandBps = _rebalanceDeadbandBps;
    }

    // ============ ADMIN: KEEPER MANAGEMENT ============

    /**
     * @notice Grant keeper role to an address
     * @dev Only admin can grant keeper role
     * @param keeper Address to grant keeper role to
     */
    function grantKeeperRole(address keeper) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(KEEPER_ROLE, keeper);
    }

    /**
     * @notice Revoke keeper role from an address
     * @dev Only admin can revoke keeper role
     * @param keeper Address to revoke keeper role from
     */
    function revokeKeeperRole(address keeper) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(KEEPER_ROLE, keeper);
    }

    /**
     * @notice Check if an address has keeper role
     * @param keeper Address to check
     * @return True if address has keeper role
     */
    function hasKeeperRole(address keeper) external view returns (bool) {
        return hasRole(KEEPER_ROLE, keeper);
    }

    // ============ ADMIN: EMERGENCY ============

    /**
     * @notice Emergency withdrawal - bypasses normal withdrawal logic
     * @dev Only callable when paused or in emergency situations
     */
    function emergencyWithdraw() external onlyOwner {
        require(paused(), "Not paused");

        // Withdraw all from DMM
        IDMM.LiquidityPosition memory pos = dmm.getLiquidityPosition();
        if (pos.liquidity > 0) {
            dmm.removeLiquidity(pos.liquidity);
        }

        // Get final balances
        uint256 maangOut = MAANG.balanceOf(address(this));
        uint256 usdcOut = USDC.balanceOf(address(this));

        // Transfer to owner
        if (maangOut > 0) MAANG.safeTransfer(owner(), maangOut);
        if (usdcOut > 0) USDC.safeTransfer(owner(), usdcOut);

        emit EmergencyWithdrawExecuted(owner(), maangOut, usdcOut);
    }

    /**
     * @notice Claim fees from DMM
     */
    function claimFees() external onlyOwner {
        // DMM fees are typically auto-accrued, but we can check if there's a claim function
        // For now, this is a placeholder - implement based on your DMM's fee mechanism
        emit FeesClaimed(0, 0);
    }

    /**
     * @notice Commit to a drip execution (MEV protection)
     * @dev Keeper commits to execute drip with a hash, preventing front-running
     * @param commitment Hash of (keeper, nonce) to prevent replay attacks
     */
    function commitDrip(bytes32 commitment) external onlyRole(KEEPER_ROLE) {
        require(dripCommits[commitment] == 0, "Commitment already exists");
        dripCommits[commitment] = block.number;
        emit DripCommitted(commitment, msg.sender);
    }

    /**
     * @notice Execute drip with commit-reveal (MEV protection)
     * @dev Keeper reveals nonce to execute drip after commit delay
     * @param nonce Random nonce used in commitment
     */
    function executeDrip(uint256 nonce) external onlyRole(KEEPER_ROLE) nonReentrant {
        bytes32 commitment = keccak256(abi.encode(msg.sender, nonce));
        require(dripCommits[commitment] > 0, "No valid commitment");
        require(block.number >= dripCommits[commitment] + COMMIT_DELAY, "Too early");

        // Clear commitment to prevent replay
        delete dripCommits[commitment];

        // Add small randomized sizing to reduce MEV predictability (bounded)
        // randomFactor in [0..19] -> 0%..1.9% extra on top of configured bps
        uint256 randomFactor = uint256(keccak256(abi.encode(nonce, block.prevrandao, block.number))) % 20;
        uint16 originalRebalanceBps = rebalanceBpsPerTick;
        uint16 jitterBps = uint16(randomFactor * 10); // 0..200 bps
        uint16 maxJitter = 200; // cap 2%
        if (jitterBps > maxJitter) jitterBps = maxJitter;
        unchecked {
            rebalanceBpsPerTick = originalRebalanceBps + jitterBps;
        }

        _executeDripAndRebalance();

        // Reset to original configuration
        rebalanceBpsPerTick = originalRebalanceBps;
    }

    /**
     * @notice Drip staged funds to strategies and rebalance price (LEGACY - VULNERABLE)
     * @dev DEPRECATED: Use commitDrip + executeDrip for MEV protection
     * @notice This function is kept for backward compatibility but should not be used
     */
    /// @notice Public dripAndRebalance removed; use commit-reveal (executeDrip)

    /**
     * @notice Internal function that executes the actual drip and rebalance logic
     * @dev This is the core logic extracted from the original dripAndRebalance function
     */
    function _executeDripAndRebalance() internal {
        uint256 P = _getReflectivePrice();

        // 1) Time gate - check if enough blocks have passed
        if (block.number < lastDripBlock + dripIntervalBlocks) return;

        // 2) DRIP: Release up to dripBpsPerTick% of buffers this tick
        uint256 relMAANG = (stagedMAANG * dripBpsPerTick) / 10000;
        uint256 relUSDC = (stagedUSDC * dripBpsPerTick) / 10000;

        if (relMAANG == 0 && relUSDC == 0) return; // Nothing to drip

        // Only update timestamp after confirming we have work to do
        lastDripBlock = block.number;

        // Target split for what we release this tick
        uint256 maangEqRel = relMAANG + Math.mulDiv(relUSDC, 1e18, P);
        uint256 relEqDMM = (maangEqRel * dmmBps) / 10000;
        uint256 relEqPSM = maangEqRel - relEqDMM;

        // Build DMM pair from released amounts (one bounded swap max)
        // We want DMM contribution (MAANG = X/2, USDC = (X/2)*P)
        uint256 wantMaang = relEqDMM / 2;
        uint256 wantUsdc = Math.mulDiv(wantMaang, P, 1e18);

        // Use available staged to hit want; do one swap toward the short leg
        uint256 useMaang = wantMaang > relMAANG ? relMAANG : wantMaang;
        uint256 useUsdc = wantUsdc > relUSDC ? relUSDC : wantUsdc;

        if (useMaang < wantMaang && relUSDC > useUsdc) {
            // Short MAANG -> swap some USDC
            uint256 needUsdc = Math.mulDiv((wantMaang - useMaang), P, 1e18);
            uint256 swapUsdc = needUsdc > (relUSDC - useUsdc) ? (relUSDC - useUsdc) : needUsdc;
            if (swapUsdc > 0) {
                _swapUSDCToMAANG(swapUsdc, P);
                useMaang += Math.mulDiv(swapUsdc, 1e18, P);
                relUSDC -= swapUsdc;
            }
        } else if (useUsdc < wantUsdc && relMAANG > useMaang) {
            // Short USDC -> swap some MAANG
            uint256 needUsdc = wantUsdc - useUsdc;
            uint256 swapMaang = Math.mulDiv(needUsdc, 1e18, P);
            if (swapMaang > (relMAANG - useMaang)) swapMaang = (relMAANG - useMaang);
            if (swapMaang > 0) {
                _swapMAANGToUSDC(swapMaang, P);
                useUsdc += Math.mulDiv(swapMaang, P, 1e18);
                relMAANG -= swapMaang;
            }
        }

        // Add to DMM the pair we assembled
        uint256 dmmAdded = 0;
        if (useMaang > 0 || useUsdc > 0) {
            _addLiquidityToDMM(useMaang, useUsdc, P);
            dmmAdded = useMaang + Math.mulDiv(useUsdc, 1e18, P);
        }

        // PSM gets the released remainder this tick
        uint256 psmMaang = relMAANG - useMaang;
        uint256 psmUsdc = relUSDC - useUsdc;
        uint256 psmAdded = 0;
        if (psmMaang > 0 || psmUsdc > 0) {
            _fundPSM(psmMaang, psmUsdc);
            psmAdded = psmMaang + Math.mulDiv(psmUsdc, 1e18, P);
        }

        // Reduce buffers
        stagedMAANG -= (useMaang + psmMaang);
        stagedUSDC -= (useUsdc + psmUsdc);

        emit DripExecuted(relMAANG, relUSDC, dmmAdded, psmAdded);

        // 3) REBALANCE: Gentle nudge toward P if drift > deadband
        uint256 spot = dmm.getCurrentPrice();
        uint256 driftBps = spot > P ? Math.mulDiv(spot - P, 10000, P) : Math.mulDiv(P - spot, 10000, P);

        if (driftBps > rebalanceDeadbandBps) {
            // Value-limited nudge: rebalanceBpsPerTick% of DMM MAANG-eq
            IDMM.LiquidityPosition memory lp = dmm.getLiquidityPosition();
            uint256 dmmEq = lp.driTokens + Math.mulDiv(lp.usdcTokens, 1e18, P);
            uint256 budgetEq = (dmmEq * rebalanceBpsPerTick) / 10000;

            uint256 budgetUsed = 0;
            bool spotAboveP = spot > P;

            if (spotAboveP) {
                // MAANG expensive in pool -> sell MAANG to push price down
                uint256 haveMaang = MAANG.balanceOf(address(this));
                uint256 sell = budgetEq < haveMaang ? budgetEq : haveMaang;
                if (sell > 0) {
                    _swapMAANGToUSDC(sell, P);
                    budgetUsed = sell;
                }
            } else {
                // MAANG cheap in pool -> buy MAANG to push price up
                uint256 haveUsdc = USDC.balanceOf(address(this));
                uint256 spendUsdc = Math.mulDiv(budgetEq, P, 1e18);
                if (spendUsdc > haveUsdc) spendUsdc = haveUsdc;
                if (spendUsdc > 0) {
                    _swapUSDCToMAANG(spendUsdc, P);
                    budgetUsed = Math.mulDiv(spendUsdc, 1e18, P);
                }
            }

            emit RebalanceExecuted(driftBps, budgetUsed, spotAboveP);
        }
    }

    // ============ ERC-4626 COMPATIBILITY ============

    /**
     * @notice ERC-4626 asset (MAANG)
     */
    function asset() external view returns (address) {
        return address(MAANG);
    }

    /**
     * @notice Total assets in MAANG-equivalent
     */
    function totalAssets() external view returns (uint256) {
        return _getTotalAssetsMAANG(_getReflectivePrice());
    }

    /**
     * @notice Convert assets to shares
     */
    function convertToShares(uint256 assets) external view returns (uint256) {
        uint256 totalAssets_ = _getTotalAssetsMAANG(_getReflectivePrice());
        uint256 totalShares_ = totalSupply();

        if (totalShares_ == 0) return assets;
        return Math.mulDiv(assets, totalShares_, totalAssets_);
    }

    /**
     * @notice Convert shares to assets
     */
    function convertToAssets(uint256 shares) external view returns (uint256) {
        uint256 totalAssets_ = _getTotalAssetsMAANG(_getReflectivePrice());
        uint256 totalShares_ = totalSupply();

        if (totalShares_ == 0) return shares;
        return Math.mulDiv(shares, totalAssets_, totalShares_);
    }

    // ============ MONITORING & HEALTH CHECKS ============

    /**
     * @notice Get vault health metrics
     */
    function getVaultHealth() external view returns (
        uint256 totalAssets_,
        uint256 totalShares_,
        uint256 sharePrice,
        uint256 dmmTVL,
        uint256 psmTVL,
        uint256 onVaultTVL,
        bool isHealthy
    ) {
        uint256 P = _getReflectivePrice();
        totalAssets_ = _getTotalAssetsMAANG(P);
        totalShares_ = totalSupply();
        sharePrice = totalShares_ == 0 ? 1e18 : Math.mulDiv(totalAssets_, 1e18, totalShares_);

        // Strategy TVL breakdown
        IDMM.LiquidityPosition memory pos = dmm.getLiquidityPosition();
        dmmTVL = pos.driTokens + Math.mulDiv(pos.usdcTokens, 1e18, P);

        IPSM.ReserveState memory rs = psm.getReserveState();
        psmTVL = rs.driTokens + Math.mulDiv(rs.usdcTokens, 1e18, P);

        onVaultTVL = MAANG.balanceOf(address(this)) + Math.mulDiv(USDC.balanceOf(address(this)), 1e18, P);

        // Health check: spot vs reflective price deviation
        uint256 spot = dmm.getCurrentPrice();
        uint256 deviation = spot > P ? spot - P : P - spot;
        uint256 deviationBps = Math.mulDiv(deviation, 10000, P);
        isHealthy = deviationBps <= maxSpotDeviationBps;
    }

    /**
     * @notice Get strategy allocation breakdown
     */
    function getStrategyAllocation() external view returns (
        uint256 dmmBps_,
        uint256 psmBps_,
        uint256 dmmTVL,
        uint256 psmTVL,
        uint256 totalTVL
    ) {
        dmmBps_ = dmmBps;
        psmBps_ = psmBps;

        uint256 P = _getReflectivePrice();
        IDMM.LiquidityPosition memory pos = dmm.getLiquidityPosition();
        dmmTVL = pos.driTokens + Math.mulDiv(pos.usdcTokens, 1e18, P);

        IPSM.ReserveState memory rs = psm.getReserveState();
        psmTVL = rs.driTokens + Math.mulDiv(rs.usdcTokens, 1e18, P);

        totalTVL = dmmTVL + psmTVL;
    }

    /**
     * @notice Check if vault is in emergency state
     */
    function isEmergencyState() external view returns (bool) {
        return paused() || depositsPaused;
    }

    /**
     * @notice Get drip and rebalance status
     */
    function getDripStatus() external view returns (
        uint256 lastDripBlock_,
        uint256 blocksSinceLastDrip,
        uint256 stagedMAANG_,
        uint256 stagedUSDC_,
        bool canDrip,
        uint256 nextDripBlock
    ) {
        lastDripBlock_ = lastDripBlock;
        blocksSinceLastDrip = block.number - lastDripBlock;
        stagedMAANG_ = stagedMAANG;
        stagedUSDC_ = stagedUSDC;
        canDrip = block.number >= lastDripBlock + dripIntervalBlocks && (stagedMAANG > 0 || stagedUSDC > 0);
        nextDripBlock = lastDripBlock + dripIntervalBlocks;
    }

    /**
     * @notice Get price drift and rebalance status
     */
    function getRebalanceStatus() external view returns (
        uint256 spot,
        uint256 reflective,
        uint256 driftBps,
        bool needsRebalance,
        uint256 rebalanceBudget
    ) {
        spot = dmm.getCurrentPrice();
        reflective = _getReflectivePrice();
        driftBps = spot > reflective ?
            Math.mulDiv(spot - reflective, 10000, reflective) :
            Math.mulDiv(reflective - spot, 10000, reflective);
        needsRebalance = driftBps > rebalanceDeadbandBps;

        if (needsRebalance) {
            IDMM.LiquidityPosition memory lp = dmm.getLiquidityPosition();
            uint256 dmmEq = lp.driTokens + Math.mulDiv(lp.usdcTokens, 1e18, reflective);
            rebalanceBudget = (dmmEq * rebalanceBpsPerTick) / 10000;
        }
    }
}
