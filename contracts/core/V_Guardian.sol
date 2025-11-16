// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract V_Guardian {
    address public admin;
    address public pendingAdmin;

    mapping(address => bool) public pauseMint;
    mapping(address => bool) public pauseBorrow;
    mapping(address => bool) public pauseRedeem;
    mapping(address => bool) public pauseLiquidation;

    event NewPendingAdmin(address indexed);
    event NewAdmin(address indexed);
    event ActionPaused(address indexed cToken, string action, bool state);

    modifier onlyAdmin() { require(msg.sender == admin, "guardian: !admin"); _; }

    constructor(address _admin) {
        admin = _admin;
    }

    function setPendingAdmin(address p) external onlyAdmin {
        pendingAdmin = p;
        emit NewPendingAdmin(p);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "guardian: !pending");
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit NewAdmin(admin);
    }

    function setPause(address cToken, string calldata action, bool state) external onlyAdmin {
        bytes32 a = keccak256(bytes(action));
        if (a == keccak256("mint")) pauseMint[cToken] = state;
        else if (a == keccak256("borrow")) pauseBorrow[cToken] = state;
        else if (a == keccak256("redeem")) pauseRedeem[cToken] = state;
        else if (a == keccak256("liquidation")) pauseLiquidation[cToken] = state;
        else revert("guardian: invalid action");
        emit ActionPaused(cToken, action, state);
    }
}