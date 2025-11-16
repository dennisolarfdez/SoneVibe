// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../core/V_MasterEnhanced.sol";

contract HealthFactorHelper {
    V_MasterEnhanced public immutable master;

    constructor(address _master) {
        master = V_MasterEnhanced(_master);
        require(master.isComptroller(), "not master");
    }

    // Health factor en mantissa 1e18: HF = liquidationUSD / borrowUSD
    // Si no hay deuda, devuelve max uint (infinito práctico)
    function getHealthFactorMantissa(address account) external view returns (uint256) {
        V_MasterEnhanced.LiquidityData memory ld = master.getAccountLiquidity(account);
        if (ld.borrowUSD == 0) return type(uint256).max;
        return (ld.liquidationUSD * 1e18) / ld.borrowUSD;
    }

    // Borrow power disponible en USD (1e18): collateralUSD - borrowUSD (no negativo)
    function getBorrowPowerUSD(address account) external view returns (uint256) {
        V_MasterEnhanced.LiquidityData memory ld = master.getAccountLiquidity(account);
        if (ld.collateralUSD <= ld.borrowUSD) return 0;
        return ld.collateralUSD - ld.borrowUSD;
    }

    // Retorna los tres valores crudos (1e18) para depurar en Remix
    function getRaw(address account)
        external
        view
        returns (uint256 collateralUSD, uint256 liquidationUSD, uint256 borrowUSD)
    {
        V_MasterEnhanced.LiquidityData memory ld = master.getAccountLiquidity(account);
        return (ld.collateralUSD, ld.liquidationUSD, ld.borrowUSD);
    }
}