// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMaskuza
/// @notice Marker for the MASKUZA collection. `isRevealed` is false until finalize stores the plain slot.
interface IMaskuza {
    /// @notice Whether finalize has stored the plain slot for `tokenId`.
    function isRevealed(uint256 tokenId) external view returns (bool);
}
