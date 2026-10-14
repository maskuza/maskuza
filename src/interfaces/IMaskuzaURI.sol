// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMaskuzaURI
/// @notice Optional metadata source. Return an empty string to fall back to the collection base URI.
interface IMaskuzaURI {
    /// @notice Metadata URI for `tokenId`, or `""` if this hook does not serve it.
    function tokenURI(uint256 tokenId) external view returns (string memory);
}
