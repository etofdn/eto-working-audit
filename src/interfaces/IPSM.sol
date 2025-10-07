// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPSM {
    struct ReserveState {
        uint256 driTokens;
        uint256 usdcTokens;
        uint256 totalValue;
        uint256 utilizationRate;
    }

    struct ArbConfig {
        uint256 swapCap; // Δ - max swap size as % of pool TVL
        uint256 maxUsdcDraw; // α - max % of USDC reserve per swap
        uint256 reserveFloor; // U_floor - minimum USDC reserve
        uint256 deviationThreshold; // ε_max - deviation trigger
        uint256 feeRate; // δ_fee - surcharge rate
    }

    event ReserveVaultFunded(uint256 driAmount, uint256 usdcAmount);
    event ArbSwapExecuted(bool isBuy, uint256 amountIn, uint256 amountOut, uint256 newPrice);
    event ReserveReplenished(uint256 usdcAmount, uint256 driMinted);
    event DrawdownThrottled(uint256 newThreshold, uint256 newCap);
    event PSMConfigUpdated(ArbConfig newConfig);

    function fundReserve(uint256 driAmount, uint256 usdcAmount) external;
    function withdrawReserve(uint256 driAmount, uint256 usdcAmount) external;
    function executeArbSwap(bool isBuy, uint256 maxAmount) external returns (uint256 amountOut);
    function replenishReserve() external returns (uint256 usdcRaised);
    function getReserveState() external view returns (ReserveState memory);
    function getArbConfig() external view returns (ArbConfig memory);
    function canExecuteArb() external view returns (bool, uint256);
    function estimateArbSize(bool isBuy) external view returns (uint256);
    function maangOf(address provider) external view returns (uint256);
    function usdcOf(address provider) external view returns (uint256);
}
