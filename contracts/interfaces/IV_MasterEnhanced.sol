// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IV_MasterEnhanced {
    function canBorrow(address account, address cToken, uint256 amount) external view returns (bool);
    function canRedeem(address account, address cToken, uint256 cTokenAmount) external view returns (bool);
    function isComptroller() external view returns (bool);
    function oracle() external view returns (address);

    function closeFactorMantissa() external view returns (uint256);
    function liquidationIncentiveMantissa() external view returns (uint256);

    function marketSupplyCaps(address cToken) external view returns (uint256);
    function marketBorrowCaps(address cToken) external view returns (uint256);

    function seizeAllowed(
        address borrower,
        address liquidator,
        address cTokenCollateral,
        address cTokenBorrowed,
        uint256 seizeTokens
    ) external view returns (bool);
}