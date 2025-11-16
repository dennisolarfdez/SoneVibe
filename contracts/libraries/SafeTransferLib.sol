// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Librería segura para transferencias ERC20 (maneja tokens que retornan bool o nada).
library SafeTransferLib {
    function safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "STL: transfer failed");
    }

    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)")), from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "STL: transferFrom failed");
    }

    function safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "STL: approve failed");
    }
}