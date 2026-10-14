// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FHE} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {euint16} from "encrypted-types/EncryptedTypes.sol";

/// @title SlotDraw
/// @notice Collision-free encrypted slot assignment for MASKUZA.
/// @dev Public functions run by delegatecall, so ACL and coprocessor config use the collection proxy.
///      The map is an unbalanced Feistel permutation of 0..665 (18 by 37). It is a bijection, so two
///      token indexes never share a slot. It is not an affine offset: one revealed point does not
///      determine the rest. Round keys stay encrypted for this contract only.
library SlotDraw {
    /// @dev Right half. 18 * 37 = 666.
    uint16 internal constant RIGHT = 37;
    /// @dev Left half.
    uint16 internal constant LEFT = 18;

    struct RoundKeys {
        euint16 key0;
        euint16 key1;
        euint16 key2;
        bool ready;
    }

    /// @notice Point the collection at the Zama coprocessor. Delegatecall writes the proxy's config.
    function configureCoprocessor() public {
        FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig());
    }

    /// @notice Draw the encrypted slot for mint index `index` (tokenId - 1) and allow `to`.
    function assign(RoundKeys storage keys, uint256 index, address to) public returns (euint16 slot) {
        if (!keys.ready) {
            keys.key0 = FHE.allowThis(FHE.randEuint16());
            keys.key1 = FHE.allowThis(FHE.randEuint16());
            keys.key2 = FHE.allowThis(FHE.randEuint16());
            keys.ready = true;
        }
        euint16 left = FHE.asEuint16(uint16(index / RIGHT));
        euint16 right = FHE.asEuint16(uint16(index % RIGHT));
        left = _mix(left, right, keys.key0, LEFT);
        right = _mix(right, left, keys.key1, RIGHT);
        left = _mix(left, right, keys.key2, LEFT);
        slot = FHE.allow(FHE.allowThis(FHE.add(FHE.mul(left, RIGHT), right)), to);
    }

    /// @notice Let `to` user-decrypt the current handle. The handle does not change.
    function grant(euint16 slot, address to) public {
        FHE.allow(slot, to);
    }

    /// @notice Mark the holder's slot ciphertext as publicly decryptable.
    function publish(euint16 slot) public returns (euint16) {
        return FHE.makePubliclyDecryptable(slot);
    }

    /// @notice Accept `clearSlot` only when the KMS proof matches this handle.
    function verify(euint16 slot, uint16 clearSlot, bytes calldata proof) public {
        bytes32[] memory handles = new bytes32[](1);
        handles[0] = euint16.unwrap(slot);
        FHE.checkSignatures(handles, abi.encode(clearSlot), proof);
    }

    /// @notice Whether `account` can use this handle. Persistent ACL, not the plaintext.
    function allowed(euint16 slot, address account) public view returns (bool) {
        return FHE.isAllowed(slot, account);
    }

    /// @dev side = (side + ((other^2 xor key) mod modulus)) mod modulus. Feistel step, so invertible.
    function _mix(euint16 side, euint16 other, euint16 key, uint16 modulus) private returns (euint16) {
        euint16 folded = FHE.rem(FHE.xor(FHE.mul(other, other), key), modulus);
        return FHE.rem(FHE.add(side, folded), modulus);
    }
}
