// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title V_UnitAdminStorage
/// @notice Debe ser el PRIMER padre en tu implementación V_MasterEnhanced para alinear storage con el proxy.
contract V_UnitAdminStorage {
    // Admin actual del proxy
    address public admin;
    // Admin propuesto (pendiente)
    address public pendingAdmin;

    // Implementación actual (V_MasterEnhanced activa)
    address public masterImplementation;
    // Implementación propuesta (pendiente de aceptación)
    address public pendingMasterImplementation;
}