// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILimitBreakTransferValidator, LIST_TYPE_WHITELIST} from "../vendor/limitbreak/ILimitBreakTransferValidator.sol";

/// @title LocalTransferValidator
/// @notice Anvil and Foundry stand-in for Limit Break's transfer validator.
/// @dev Not for Sepolia or mainnet. Those chains use the canonical validator.
contract LocalTransferValidator is ILimitBreakTransferValidator {
    struct Policy {
        uint8 rulesetId;
        uint8 globalOptions;
        uint16 rulesetOptions;
        uint48 listId;
    }

    /// @dev Ruleset option bit 0. When set, the holder cannot transfer the token themselves.
    uint16 private constant BLOCK_HOLDER_TRANSFERS = 1 << 0;
    /// @dev Ruleset option bit 2. When set, a contract that holds the token may transfer it.
    uint16 private constant ALLOW_CONTRACT_HOLDER_TRANSFERS = 1 << 2;

    uint48 public lastListId;
    mapping(uint48 id => address owner) public listOwners;
    mapping(uint48 id => mapping(address account => bool)) public whitelisted;
    mapping(address collection => Policy) public policies;

    error CallerMustBeWhitelisted();
    error NotListOwner();
    error NotCollectionAuthority();
    error WrongListType();

    function createList(string calldata) external returns (uint48 id) {
        id = ++lastListId;
        listOwners[id] = msg.sender;
    }

    function addAccountsToList(uint48 id, uint8 listType, address[] calldata accounts) external {
        if (listOwners[id] != msg.sender) revert NotListOwner();
        if (listType != LIST_TYPE_WHITELIST) revert WrongListType();
        for (uint256 i = 0; i < accounts.length; ++i) {
            whitelisted[id][accounts[i]] = true;
        }
    }

    function applyListToCollection(address collection, uint48 id) external {
        _requireCollectionAuthority(collection);
        policies[collection].listId = id;
    }

    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external {
        _requireCollectionAuthority(collection);
        Policy storage policy = policies[collection];
        policy.rulesetId = rulesetId;
        policy.globalOptions = globalOptions;
        policy.rulesetOptions = rulesetOptions;
    }

    function validateTransfer(address caller, address from, address to, uint256) external view {
        if (from == address(0) || to == address(0)) return;
        Policy memory policy = policies[msg.sender];
        bool blockHolderTransfers = (policy.rulesetOptions & BLOCK_HOLDER_TRANSFERS) != 0;
        bool allowContractHolderTransfers = (policy.rulesetOptions & ALLOW_CONTRACT_HOLDER_TRANSFERS) != 0;
        if (caller == from) {
            if (caller.code.length == 0 && !blockHolderTransfers) return;
            if (caller.code.length > 0 && allowContractHolderTransfers) return;
        }
        if (policy.listId != 0 && whitelisted[policy.listId][caller]) return;
        revert CallerMustBeWhitelisted();
    }

    function _requireCollectionAuthority(address collection) internal view {
        if (msg.sender == collection) return;
        (bool ok, bytes memory data) = collection.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && data.length >= 32 && abi.decode(data, (address)) == msg.sender) return;
        revert NotCollectionAuthority();
    }
}
