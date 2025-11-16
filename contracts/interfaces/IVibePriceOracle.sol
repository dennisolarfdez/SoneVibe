// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IVibePriceOracle {
    function getUnderlyingPrice(address cToken) external view returns (uint256);
}