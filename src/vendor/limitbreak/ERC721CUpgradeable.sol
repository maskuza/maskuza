// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ICreatorToken} from "@limitbreak/creator-token-standards/src/interfaces/ICreatorToken.sol";
import {ICreatorTokenLegacy} from "@limitbreak/creator-token-standards/src/interfaces/ICreatorTokenLegacy.sol";
import {
    AutomaticValidatorTransferApproval
} from "@limitbreak/creator-token-standards/src/utils/AutomaticValidatorTransferApproval.sol";
import {CreatorTokenBase} from "@limitbreak/creator-token-standards/src/utils/CreatorTokenBase.sol";

/// @title ERC721CUpgradeable
/// @notice Adapted Limit Break ERC-721C for OpenZeppelin 5 upgradeable contracts.
/// @dev Limit Break's `ERC721CInitializable` is for clones and uses `_beforeTokenTransfer`.
///      This wrapper keeps `CreatorTokenBase` and checks transfers in `_update`.
///      Do not add linear state variables. See NAMING.md.
abstract contract ERC721CUpgradeable is ERC721Upgradeable, CreatorTokenBase, AutomaticValidatorTransferApproval {
    /// @dev Token type registered with the transfer validator.
    uint16 internal constant TOKEN_TYPE_ERC721 = 721;

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ICreatorToken).interfaceId || interfaceId == type(ICreatorTokenLegacy).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Whether `operator` may move `owner`'s tokens.
    function isApprovedForAll(address owner, address operator) public view virtual override returns (bool isApproved) {
        isApproved = super.isApprovedForAll(owner, operator);
        if (!isApproved && autoApproveTransfersFromValidator) {
            isApproved = operator == getTransferValidator();
        }
    }

    /// @notice Transfer check the validator should call.
    /// @return functionSignature `validateTransfer(address,address,address,uint256)`.
    /// @return isViewFunction True. The check does not modify state.
    function getTransferValidationFunction() external pure returns (bytes4 functionSignature, bool isViewFunction) {
        functionSignature = bytes4(keccak256("validateTransfer(address,address,address,uint256)"));
        isViewFunction = true;
    }

    /// @dev Mints, burns, and transfers are checked by the transfer validator.
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address from) {
        from = _ownerOf(tokenId);
        _validateBeforeTransfer(from, to, tokenId);
        from = super._update(to, tokenId, auth);
        _validateAfterTransfer(from, to, tokenId);
    }

    function _tokenType() internal pure override returns (uint16) {
        return TOKEN_TYPE_ERC721;
    }

    function _msgSender() internal view virtual override(Context, ContextUpgradeable) returns (address) {
        return ContextUpgradeable._msgSender();
    }

    function _msgData() internal view virtual override(Context, ContextUpgradeable) returns (bytes calldata) {
        return ContextUpgradeable._msgData();
    }

    function _contextSuffixLength() internal view virtual override(Context, ContextUpgradeable) returns (uint256) {
        return ContextUpgradeable._contextSuffixLength();
    }
}
