// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./V_UnitAdminStorage.sol";

/// @title V_Unit (Unitroller-like Proxy para V_MasterEnhanced)
contract V_Unit is V_UnitAdminStorage {
    event NewPendingImplementation(address indexed oldPendingImplementation, address indexed newPendingImplementation);
    event NewImplementation(address indexed oldImplementation, address indexed newImplementation);
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "V_Unit: not admin");
        _;
    }

    constructor(address initialAdmin) {
        require(initialAdmin != address(0), "V_Unit: zero admin");
        admin = initialAdmin;
    }

    // Implementación
    function _setPendingImplementation(address newPendingImplementation) external onlyAdmin {
        address oldPending = pendingMasterImplementation;
        pendingMasterImplementation = newPendingImplementation;
        emit NewPendingImplementation(oldPending, newPendingImplementation);
    }

    function _acceptImplementation() external {
        require(msg.sender == pendingMasterImplementation, "V_Unit: only pending impl");
        address oldImpl = masterImplementation;
        masterImplementation = pendingMasterImplementation;
        pendingMasterImplementation = address(0);
        emit NewImplementation(oldImpl, masterImplementation);
    }

    function getImplementation() external view returns (address) {
        return masterImplementation;
    }

    // Admin
    function _setPendingAdmin(address newPendingAdmin) external onlyAdmin {
        address oldPending = pendingAdmin;
        pendingAdmin = newPendingAdmin;
        emit NewPendingAdmin(oldPending, newPendingAdmin);
    }

    function _acceptAdmin() external {
        require(msg.sender == pendingAdmin, "V_Unit: only pending admin");
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit NewAdmin(oldAdmin, admin);
    }

    // Fallback
    receive() external payable {}
    fallback() external payable {
        address impl = masterImplementation;
        require(impl != address(0), "V_Unit: impl not set");
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}