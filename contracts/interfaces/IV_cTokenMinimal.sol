// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IV_cTokenMinimal {
    function balanceOf(address owner) external view returns (uint256);
    function borrowBalance(address owner) external view returns (uint256); // deuda con intereses
    function underlying() external view returns (address);
    function underlyingDecimals() external view returns (uint8);
    function exchangeRateStored() external view returns (uint256);
}