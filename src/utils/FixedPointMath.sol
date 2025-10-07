// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library FixedPointMath {
    uint256 constant SCALE = 1e18;
    uint256 constant HALF_SCALE = 5e17;

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "FixedPointMath: multiplication overflow");
        return (c + HALF_SCALE) / SCALE;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "FixedPointMath: division by zero");
        return (a * SCALE + b / 2) / b;
    }

    function fraction(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        require(denominator > 0, "FixedPointMath: division by zero");
        return (numerator * SCALE) / denominator;
    }

    function percentage(uint256 value, uint256 percent) internal pure returns (uint256) {
        return (value * percent) / (100 * SCALE);
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function cap(uint256 value, uint256 maxValue) internal pure returns (uint256) {
        return value > maxValue ? maxValue : value;
    }

    function applyCapFactor(uint256 baseValue, uint256 factor, uint256 maxDelta) internal pure returns (uint256) {
        if (factor == SCALE) return baseValue;

        uint256 delta;
        if (factor > SCALE) {
            delta = min((factor - SCALE) * baseValue / SCALE, maxDelta);
            return baseValue + delta;
        } else {
            delta = min((SCALE - factor) * baseValue / SCALE, maxDelta);
            return baseValue - delta;
        }
    }

    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) return 0;

        uint256 result = 1;
        uint256 x = a;

        if (x >= 0x100000000000000000000000000000000) {
            x >>= 128;
            result <<= 64;
        }
        if (x >= 0x10000000000000000) {
            x >>= 64;
            result <<= 32;
        }
        if (x >= 0x100000000) {
            x >>= 32;
            result <<= 16;
        }
        if (x >= 0x10000) {
            x >>= 16;
            result <<= 8;
        }
        if (x >= 0x100) {
            x >>= 8;
            result <<= 4;
        }
        if (x >= 0x10) {
            x >>= 4;
            result <<= 2;
        }
        if (x >= 0x8) {
            result <<= 1;
        }

        result = (result + a / result) >> 1;
        result = (result + a / result) >> 1;
        result = (result + a / result) >> 1;
        result = (result + a / result) >> 1;
        result = (result + a / result) >> 1;
        result = (result + a / result) >> 1;
        result = (result + a / result) >> 1;

        uint256 roundedDownResult = a / result;
        return result >= roundedDownResult ? roundedDownResult : result;
    }
}
