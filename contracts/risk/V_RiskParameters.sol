// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract V_RiskParameters {
    address public admin;
    mapping(address => uint256) public supplyCaps;
    mapping(address => uint256) public borrowCaps;
    uint256 public userBorrowCapGlobal;

    event SupplyCapSet(address indexed cToken, uint256 cap);
    event BorrowCapSet(address indexed cToken, uint256 cap);
    event UserBorrowCapGlobalSet(uint256 cap);

    modifier onlyAdmin() { require(msg.sender == admin, "risk: !admin"); _; }

    constructor(address _admin) { admin = _admin; }

    function setSupplyCap(address cToken, uint256 cap) external onlyAdmin {
        supplyCaps[cToken] = cap;
        emit SupplyCapSet(cToken, cap);
    }

    function setBorrowCap(address cToken, uint256 cap) external onlyAdmin {
        borrowCaps[cToken] = cap;
        emit BorrowCapSet(cToken, cap);
    }

    function setUserBorrowCapGlobal(uint256 cap) external onlyAdmin {
        userBorrowCapGlobal = cap;
        emit UserBorrowCapGlobalSet(cap);
    }
}