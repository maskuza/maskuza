// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ILimitBreakTransferValidator
/// @notice The Limit Break transfer-validator calls MASKUZA makes.
/// @dev Canonical address: `0x721C008fdff27BF06E7E123956E2Fe03B63342e3`. See NAMING.md.
interface ILimitBreakTransferValidator {
    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;

    function createList(string calldata name) external returns (uint48 id);

    function addAccountsToList(uint48 id, uint8 listType, address[] calldata accounts) external;

    function applyListToCollection(address collection, uint48 id) external;

    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
}

/// @dev Whitelist ruleset. Contract operators must be listed. Wallet-to-wallet transfers stay open.
uint8 constant RULESET_ID_WHITELIST = 4;

/// @dev `addAccountsToList` type for allowed operators.
uint8 constant LIST_TYPE_WHITELIST = 1;

/// @dev Also use Limit Break's built-in operator list.
uint8 constant FLAG_GLOBAL_CUSTOM_LIST_SUPPLEMENTS_DEFAULT_LIST = 1 << 3;
