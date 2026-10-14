// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SSTORE2} from "./SSTORE2.sol";

/// @title SealedMetadata
/// @notice Builds the data URI for an unrevealed MASKUZA token.
/// @dev The PNG lives in an SSTORE2 contract. This library base64-encodes it into an SVG, then into JSON.
library SealedMetadata {
    using Strings for uint256;

    /// @dev Name, this description, and the image. The JSON has no attributes field.
    string internal constant DESCRIPTION = "666 MASKUZA. Unrevealed.";

    /// @notice `data:application/json;base64,...` for `tokenId`, using the PNG stored at `art`.
    function uri(address art, uint256 tokenId) public view returns (string memory) {
        string memory png = Base64.encode(SSTORE2.read(art));
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">',
            '<image href="data:image/png;base64,',
            png,
            '" width="100" height="100" style="image-rendering: pixelated"/>',
            "</svg>"
        );
        string memory json = string.concat(
            '{"name":"MASKUZA #',
            tokenId.toString(),
            '","description":"',
            DESCRIPTION,
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
