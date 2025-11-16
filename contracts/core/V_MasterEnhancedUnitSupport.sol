// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../proxy/V_UnitAdminStorage.sol";

interface IV_Unit {
    function pendingMasterImplementation() external view returns (address);
    function _acceptImplementation() external;
    function admin() external view returns (address);
}

/// @title V_MasterEnhancedUnitSupport
/// @notice Mixin para que tu implementación pueda convertirse en la activa del proxy V_Unit.
///         Importante: este mixin NO define isComptroller() para evitar colisión con IV_MasterEnhanced.
abstract contract V_MasterEnhancedUnitSupport is V_UnitAdminStorage {
    /// @notice Llamado por la implementación para convertirse en la implementación activa del proxy
    function _become(address unit) external {
        require(IV_Unit(unit).pendingMasterImplementation() == address(this), "V_Master: not pending impl");
        IV_Unit(unit)._acceptImplementation();
        _becomeInitialize(unit);
    }

    /// @notice Hook opcional post-upgrade (puedes override en tu implementación si quieres inicializar algo extra)
    function _becomeInitialize(address /*unit*/) internal virtual {}

    /// @notice Resign opcional al ser reemplazada la implementación
    function _resign() external virtual {}
}
