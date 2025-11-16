// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IInterestRateModel.sol";

contract JumpRateModel is IInterestRateModel {
    uint256 public immutable baseRatePerBlock;
    uint256 public immutable slope1PerBlock;
    uint256 public immutable slope2PerBlock;
    uint256 public immutable kink; // utilization mantissa (1e18)

    constructor(
        uint256 _baseRatePerBlock,
        uint256 _slope1PerBlock,
        uint256 _slope2PerBlock,
        uint256 _kink
    ) {
        require(_kink <= 1e18, "kink>1");
        baseRatePerBlock = _baseRatePerBlock;
        slope1PerBlock = _slope1PerBlock;
        slope2PerBlock = _slope2PerBlock;
        kink = _kink;
    }

    function isInterestRateModel() external pure returns (bool) {
        return true;
    }

    function getBorrowRate(
        uint cash,
        uint borrows,
        uint reserves
    ) public view override returns (uint) {
        if (borrows == 0) return baseRatePerBlock;

        uint utilization = borrows * 1e18 / (cash + borrows - reserves);
        if (utilization <= kink) {
            // linear region
            return baseRatePerBlock + (utilization * slope1PerBlock / 1e18);
        } else {
            uint excess = utilization - kink;
            return baseRatePerBlock
                + (kink * slope1PerBlock / 1e18)
                + (excess * slope2PerBlock / 1e18);
        }
    }

    function getSupplyRate(
        uint cash,
        uint borrows,
        uint reserves,
        uint reserveFactorMantissa
    ) external view override returns (uint) {
        if (borrows == 0) return 0;
        uint borrowRate = getBorrowRate(cash, borrows, reserves);
        uint utilization = borrows * 1e18 / (cash + borrows - reserves);
        uint oneMinusReserve = 1e18 - reserveFactorMantissa;
        // r_s = r_b * U * (1 - reserveFactor)
        return borrowRate * utilization / 1e18 * oneMinusReserve / 1e18;
    }
}