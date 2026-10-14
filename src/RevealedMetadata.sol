// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {SSTORE2} from "./SSTORE2.sol";

/// @title RevealedMetadata
/// @notice JSON data URI for a revealed mask. The PNG is read from an SSTORE2 contract.
library RevealedMetadata {
    struct Attribute {
        string traitType;
        string value;
    }

    /// @notice `data:application/json;base64,...` with `attributes` and a pixelated SVG image.
    function uri(string memory name, string memory description, Attribute[] memory attributes, address pngPointer)
        public
        view
        returns (string memory)
    {
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">',
            '<image href="data:image/png;base64,',
            Base64.encode(SSTORE2.read(pngPointer)),
            '" width="100" height="100" style="image-rendering: pixelated"/>',
            "</svg>"
        );
        string memory json = string.concat(
            '{"name":',
            _quote(name),
            ',"description":',
            _quote(description),
            ',"attributes":',
            _attributes(attributes),
            ',"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _attributes(Attribute[] memory attributes) internal pure returns (string memory out) {
        out = "[";
        for (uint256 i; i < attributes.length; ++i) {
            if (i != 0) out = string.concat(out, ",");
            out = string.concat(
                out, '{"trait_type":', _quote(attributes[i].traitType), ',"value":', _quote(attributes[i].value), "}"
            );
        }
        out = string.concat(out, "]");
    }

    /// @dev JSON string. Quotes, backslashes, and control bytes are escaped.
    function _quote(string memory text) internal pure returns (string memory) {
        bytes memory raw = bytes(text);
        uint256 extra;
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            if (c == '"' || c == "\\" || c == "\n" || c == "\r" || c == "\t") extra += 1;
            else if (uint8(c) < 0x20) extra += 5;
        }
        if (extra == 0) return string.concat('"', text, '"');
        bytes memory out = new bytes(raw.length + extra + 2);
        out[0] = '"';
        uint256 n = 1;
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            if (c == '"') {
                out[n++] = "\\";
                out[n++] = '"';
            } else if (c == "\\") {
                out[n++] = "\\";
                out[n++] = "\\";
            } else if (c == "\n") {
                out[n++] = "\\";
                out[n++] = "n";
            } else if (c == "\r") {
                out[n++] = "\\";
                out[n++] = "r";
            } else if (c == "\t") {
                out[n++] = "\\";
                out[n++] = "t";
            } else if (uint8(c) < 0x20) {
                out[n++] = "\\";
                out[n++] = "u";
                out[n++] = "0";
                out[n++] = "0";
                out[n++] = _hex(uint8(c) >> 4);
                out[n++] = _hex(uint8(c) & 0x0f);
            } else {
                out[n++] = c;
            }
        }
        out[n] = '"';
        return string(out);
    }

    function _hex(uint8 value) internal pure returns (bytes1) {
        return value < 10 ? bytes1(value + 0x30) : bytes1(value + 0x57);
    }
}
