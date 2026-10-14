// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SSTORE2
/// @notice Writes bytes into a new contract and reads them back from its bytecode.
/// @dev The runtime code starts with STOP, so a call into the data contract does nothing.
library SSTORE2 {
    error DeploymentFailed();
    error ReadOutOfBounds();

    uint256 internal constant DATA_OFFSET = 1;

    /// @notice Deploy `data` and return the contract that holds it.
    function write(bytes memory data) internal returns (address pointer) {
        bytes memory runtimeCode = abi.encodePacked(hex"00", data);
        if (runtimeCode.length > 24_575) revert DeploymentFailed();

        bytes memory creationCode =
            abi.encodePacked(hex"63", uint32(runtimeCode.length), hex"80600E6000396000F3", runtimeCode);

        assembly {
            pointer := create(0, add(creationCode, 32), mload(creationCode))
        }
        if (pointer == address(0)) revert DeploymentFailed();
    }

    /// @notice Read the bytes stored at `pointer`, without the leading STOP.
    function read(address pointer) internal view returns (bytes memory data) {
        uint256 size = pointer.code.length;
        if (size <= DATA_OFFSET) revert ReadOutOfBounds();
        uint256 length = size - DATA_OFFSET;
        data = new bytes(length);
        assembly {
            extcodecopy(pointer, add(data, 32), 1, length)
        }
    }
}
