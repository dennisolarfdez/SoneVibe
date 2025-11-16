// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Ejemplo de modelo de interés lineal: borrowRate = base + util * slope
/// No integrado aún con el cToken anterior (necesitarías agregar lógica de accrual).
contract SimpleInterestRateModel {
    uint256 public immutable baseRatePerYear;  // ej. 0.02e18 = 2%
    uint256 public immutable slopePerYear;     // ej. 0.18e18 = 18%
    uint256 public constant YEAR = 365 days;

    constructor(uint256 _baseRate, uint256 _slope) {
        baseRatePerYear = _baseRate;
        slopePerYear = _slope;
    }

    function getBorrowRate(uint256 cash, uint256 borrows) external pure returns (uint256) {
        if (borrows == 0) return 0;
        uint256 util = borrows * 1e18 / (cash + borrows);
        // Por año
        return util; // placeholder: sería baseRate + util*slope normalmente
    }
}