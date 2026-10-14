// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {RevealedMetadata} from "./RevealedMetadata.sol";
import {SealedMetadata} from "./SealedMetadata.sol";
import {SSTORE2} from "./SSTORE2.sol";

/// @title ArtPool
/// @notice Sealed chest and the 666-slot revealed pool. Storage is the collection proxy's.
/// @dev Public functions are delegatecalls. A slot is not a token id.
library ArtPool {
    using Strings for uint256;

    uint256 internal constant MAX_SUPPLY = 666;
    uint256 internal constant MAX_BATCH = 8;
    uint256 internal constant MAX_ATTRIBUTES = 16;
    string internal constant PLACEHOLDER = "Behind every mask, a secret only its holder can read. 666 MASKUZA, fully onchain.";

    error ArtMissing();
    error ArtInvalid();
    error ArtLocked();
    error ArrayLengthMismatch();
    error BatchTooLarge();
    error ArtIncomplete(uint256 uploaded);

    event RevealedArtSet(uint256 indexed slot, address indexed pointer, uint256 pngSize);

    /// @custom:storage-location erc7201:maskuza.artpool
    struct Layout {
        address sealedArt;
        bool locked;
        mapping(uint256 slot => address pointer) png;
        mapping(uint256 slot => string description) description;
        mapping(uint256 slot => RevealedMetadata.Attribute[]) attributes;
        // Appended after e122564. Number of distinct slots 0..665 that hold a PNG.
        uint256 uploaded;
    }

    // keccak256(abi.encode(uint256(keccak256("maskuza.artpool")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAYOUT_SLOT = 0x84fb2e898b5bcfec1fd7bd4f7a15aa7d2cebcc98a38b69d57161d85ca0e4df00;

    function sealedArt() public view returns (address) {
        return _layout().sealedArt;
    }

    function locked() public view returns (bool) {
        return _layout().locked;
    }

    /// @notice Store the 100 by 100 sealed PNG. Returns the SSTORE2 pointer.
    function writeSealed(bytes calldata png) public returns (address pointer) {
        if (!_isPng(png)) revert ArtInvalid();
        pointer = SSTORE2.write(png);
        _layout().sealedArt = pointer;
    }

    /// @notice Unrevealed data URI. Reverts when the chest has not been uploaded.
    function sealedUri(uint256 tokenId) public view returns (string memory) {
        address art = _layout().sealedArt;
        if (art == address(0)) revert ArtMissing();
        return SealedMetadata.uri(art, tokenId);
    }

    /// @notice Store pool PNGs at slots. Replaces a slot until the pool is locked.
    function setRevealed(
        uint256[] calldata slots,
        bytes[] calldata pngs,
        string[] calldata descriptions,
        string[][] calldata traitTypes,
        string[][] calldata values
    ) public {
        Layout storage $ = _layout();
        if ($.locked) revert ArtLocked();
        uint256 n = slots.length;
        if (n == 0 || n > MAX_BATCH) revert BatchTooLarge();
        if (pngs.length != n || descriptions.length != n || traitTypes.length != n || values.length != n) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i; i < n; ++i) {
            _store($, slots[i], pngs[i], descriptions[i], traitTypes[i], values[i]);
        }
    }

    function lock() public {
        Layout storage $ = _layout();
        if ($.locked) revert ArtLocked();
        if ($.uploaded != MAX_SUPPLY) revert ArtIncomplete($.uploaded);
        $.locked = true;
    }

    /// @notice Distinct pool slots that have been uploaded at least once.
    function uploaded() public view returns (uint256) {
        return _layout().uploaded;
    }

    function poolArt(uint256 slot) public view returns (address png, string memory description, uint256 attributes) {
        Layout storage $ = _layout();
        return ($.png[slot], $.description[slot], $.attributes[slot].length);
    }

    function poolAttribute(uint256 slot, uint256 index)
        public
        view
        returns (string memory traitType, string memory value)
    {
        RevealedMetadata.Attribute storage item = _layout().attributes[slot][index];
        return (item.traitType, item.value);
    }

    /// @notice Revealed JSON for `tokenId` using pool `slot`. Empty when that slot has no PNG.
    function revealedUri(uint256 tokenId, uint16 slot) public view returns (string memory) {
        Layout storage $ = _layout();
        address png = $.png[slot];
        if (png == address(0)) return "";
        string memory description = $.description[slot];
        if (bytes(description).length == 0) description = PLACEHOLDER;
        return
            RevealedMetadata.uri(string.concat("MASKUZA #", tokenId.toString()), description, $.attributes[slot], png);
    }

    function _store(
        Layout storage $,
        uint256 slot,
        bytes calldata png,
        string calldata description,
        string[] calldata traitTypes,
        string[] calldata values
    ) private {
        if (slot >= MAX_SUPPLY) revert ArtInvalid();
        if (!_isPng(png)) revert ArtInvalid();
        if (traitTypes.length != values.length || traitTypes.length > MAX_ATTRIBUTES) revert ArtInvalid();
        address pointer = SSTORE2.write(png);
        if ($.png[slot] == address(0)) ++$.uploaded;
        $.png[slot] = pointer;
        $.description[slot] = description;
        delete $.attributes[slot];
        for (uint256 i; i < traitTypes.length; ++i) {
            $.attributes[slot].push(RevealedMetadata.Attribute(traitTypes[i], values[i]));
        }
        emit RevealedArtSet(slot, pointer, png.length);
    }

    function _isPng(bytes calldata png) private pure returns (bool) {
        if (png.length < 24) return false;
        if (bytes8(png[0:8]) != 0x89504E470D0A1A0A) return false;
        if (bytes4(png[12:16]) != "IHDR") return false;
        uint32 width = uint32(bytes4(png[16:20]));
        uint32 height = uint32(bytes4(png[20:24]));
        return width == 100 && height == 100;
    }

    function _layout() private pure returns (Layout storage $) {
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }
}
