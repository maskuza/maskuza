// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC721CUpgradeable} from "./vendor/limitbreak/ERC721CUpgradeable.sol";
import {IMaskuza} from "./interfaces/IMaskuza.sol";
import {IMaskuzaURI} from "./interfaces/IMaskuzaURI.sol";
import {euint16} from "encrypted-types/EncryptedTypes.sol";
import {ArtPool} from "./ArtPool.sol";
import {SlotDraw} from "./SlotDraw.sol";
import {
    ILimitBreakTransferValidator,
    FLAG_GLOBAL_CUSTOM_LIST_SUPPLEMENTS_DEFAULT_LIST,
    LIST_TYPE_WHITELIST,
    RULESET_ID_WHITELIST
} from "./vendor/limitbreak/ILimitBreakTransferValidator.sol";

/// @title Maskuza
/// @notice 666 masks. Unrevealed tokens serve the onchain sealed image.
/// @dev UUPS proxy. The mint phase is derived from `startTime`. Royalty is fixed at 5%.
///      Each wallet may mint once per phase, and at most `maxPerWallet` tokens in total (default 2).
contract Maskuza is
    Initializable,
    ERC721CUpgradeable,
    ERC2981Upgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IMaskuza
{
    using Strings for uint256;

    enum Phase {
        Closed,
        Gtd,
        Whitelist,
        Public
    }

    /// @custom:storage-location erc7201:maskuza.collection
    struct MaskuzaStorage {
        address uriHook;
        uint256 totalMinted;
        uint64 startTime;
        uint64 gtdDuration;
        uint64 whitelistDuration;
        uint256 maxPerWallet;
        uint256 gtdPrice;
        uint256 whitelistPrice;
        uint256 publicPrice;
        bytes32 gtdRoot;
        bytes32 whitelistRoot;
        uint48 operatorWhitelistId;
        string baseURI;
        string uriSuffix;
        mapping(address wallet => uint256 count) mintedByWallet;
        mapping(Phase phase => mapping(address wallet => uint256 count)) mintedInPhase;
        mapping(uint256 tokenId => bool) revealed;
        mapping(uint256 tokenId => euint16 handle) encryptedSlot;
        mapping(uint256 tokenId => uint16 slot) clearSlot;
        mapping(uint256 slot => bool used) slotUsed;
        mapping(uint256 tokenId => bool requested) revealRequested;
        SlotDraw.RoundKeys roundKeys;
    }

    // keccak256(abi.encode(uint256(keccak256("maskuza.collection")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MASKUZA_STORAGE_LOCATION =
        0xaf062e947b302b6e3778bc9c6dc5098147253ab15317c07733c4e83db316b500;

    uint256 public constant MAX_SUPPLY = 666;
    /// @dev One token per wallet inside a single phase. Not owner-configurable.
    uint256 public constant MINTS_PER_PHASE = 1;
    uint256 public constant DEFAULT_MAX_PER_WALLET = 2;
    uint64 public constant DEFAULT_PHASE_DURATION = 1 hours;
    uint256 public constant DEFAULT_GTD_PRICE = 0.001 ether;
    uint256 public constant DEFAULT_WHITELIST_PRICE = 0.0015 ether;
    uint256 public constant DEFAULT_PUBLIC_PRICE = 0.002 ether;
    /// @dev Receiver can change. This rate cannot.
    uint96 public constant ROYALTY_BPS = 500;
    /// @dev Host HCU cap is 20_000_000. One draw is about 5_000_000, so three fit and four may not.
    uint256 public constant MAX_DRAW_PER_TX = 3;
    /// @dev Used when a pool slot has art but the owner left the description empty.
    string public constant REVEALED_DESCRIPTION = "Behind every mask, a secret only its holder can read. 666 MASKUZA, fully onchain.";

    error MintClosed();
    error InvalidQuantity();
    error SoldOut();
    error WalletCapExceeded();
    error PhaseLimitExceeded();
    error IncorrectPayment();
    error NotOnMintList();
    error NotHolder();
    error AlreadyRevealed();
    error ZeroAddress();
    error NothingToWithdraw();
    error WithdrawFailed();
    error PhaseNotConfigurable();
    error ArtMissing();
    error ArtInvalid();
    error ArtLocked();
    error ArrayLengthMismatch();
    error BatchTooLarge();
    error ArtIncomplete(uint256 uploaded);
    error HookNotContract();
    error DrawBatchTooLarge();
    error RevealNotRequested();
    error SlotTaken();

    event Minted(address indexed minter, uint256 quantity, uint256 payment);
    event OwnerMinted(address indexed to, uint256 quantity);
    event RevealRequested(uint256 indexed tokenId, address indexed holder, bytes32 slotHandle);
    event RevealFinalized(uint256 indexed tokenId, uint16 slot);
    event StartTimeSet(uint64 startTime);
    event PhasePriceSet(Phase phase, uint256 price);
    event PhaseDurationSet(Phase phase, uint64 duration);
    event MerkleRootSet(Phase phase, bytes32 root);
    event MaxPerWalletSet(uint256 maxPerWallet);
    event BaseURISet(string baseURI);
    event SealedArtSet(address indexed pointer, uint256 size);
    event RevealedArtSet(uint256 indexed slot, address indexed pointer, uint256 pngSize);
    event RevealedArtLocked();
    event URIHookSet(address indexed uriHook);
    event URISuffixSet(string uriSuffix);
    event Withdrawn(address indexed to, uint256 amount);
    event RoyaltyReceiverSet(address indexed receiver, uint96 bps);
    event OperatorWhitelisted(address indexed validator, uint48 listId, address indexed operator);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. Mint stays closed until the owner sets a start time.
    /// @param royaltyReceiver Account that receives the 5% royalty.
    /// @param transferValidator_ Transfer validator, or zero to keep the default validator.
    function initialize(address royaltyReceiver, address transferValidator_) external initializer {
        if (royaltyReceiver == address(0)) revert ZeroAddress();

        __ERC721_init("MASKUZA", "MASK");
        __ERC2981_init();
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        SlotDraw.configureCoprocessor();

        MaskuzaStorage storage $ = _maskuzaStorage();
        $.gtdDuration = DEFAULT_PHASE_DURATION;
        $.whitelistDuration = DEFAULT_PHASE_DURATION;
        $.maxPerWallet = DEFAULT_MAX_PER_WALLET;
        $.gtdPrice = DEFAULT_GTD_PRICE;
        $.whitelistPrice = DEFAULT_WHITELIST_PRICE;
        $.publicPrice = DEFAULT_PUBLIC_PRICE;
        _setDefaultRoyalty(royaltyReceiver, ROYALTY_BPS);

        _emitDefaultTransferValidator();
        if (transferValidator_ != address(0)) {
            setTransferValidator(transferValidator_);
        } else {
            _registerTokenType(getTransferValidator());
        }
    }

    /// @notice Current phase from `block.timestamp`. Zero `startTime` is closed.
    function phase() external view returns (Phase) {
        return _currentPhase(_maskuzaStorage());
    }

    function totalMinted() external view returns (uint256) {
        return _maskuzaStorage().totalMinted;
    }

    function startTime() external view returns (uint64) {
        return _maskuzaStorage().startTime;
    }

    function gtdDuration() external view returns (uint64) {
        return _maskuzaStorage().gtdDuration;
    }

    function whitelistDuration() external view returns (uint64) {
        return _maskuzaStorage().whitelistDuration;
    }

    function maxPerWallet() external view returns (uint256) {
        return _maskuzaStorage().maxPerWallet;
    }

    function gtdPrice() external view returns (uint256) {
        return _maskuzaStorage().gtdPrice;
    }

    function whitelistPrice() external view returns (uint256) {
        return _maskuzaStorage().whitelistPrice;
    }

    function publicPrice() external view returns (uint256) {
        return _maskuzaStorage().publicPrice;
    }

    function gtdRoot() external view returns (bytes32) {
        return _maskuzaStorage().gtdRoot;
    }

    function whitelistRoot() external view returns (bytes32) {
        return _maskuzaStorage().whitelistRoot;
    }

    function mintedByWallet(address wallet) external view returns (uint256) {
        return _maskuzaStorage().mintedByWallet[wallet];
    }

    /// @notice How many tokens `wallet` has minted in `phase_`.
    function mintedInPhase(Phase phase_, address wallet) external view returns (uint256) {
        return _maskuzaStorage().mintedInPhase[phase_][wallet];
    }

    function baseURI() external view returns (string memory) {
        return _maskuzaStorage().baseURI;
    }

    /// @notice Bytecode contract that holds the sealed PNG. Zero until the owner uploads it.
    function sealedArt() external view returns (address) {
        return ArtPool.sealedArt();
    }

    function uriHook() external view returns (address) {
        return _maskuzaStorage().uriHook;
    }

    function uriSuffix() external view returns (string memory) {
        return _maskuzaStorage().uriSuffix;
    }

    /// @notice Id of the operator whitelist on the transfer validator. Zero before the first whitelist.
    function operatorWhitelistId() external view returns (uint48) {
        return _maskuzaStorage().operatorWhitelistId;
    }

    /// @notice Whether `tokenId` has a finalized plain slot. False while the chest is still served.
    function isRevealed(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return _maskuzaStorage().revealed[tokenId];
    }

    /// @notice Holder's encrypted slot handle. User-decrypt this off-chain. It is not the art.
    function encryptedSlot(uint256 tokenId) external view returns (bytes32) {
        _requireOwned(tokenId);
        return euint16.unwrap(_maskuzaStorage().encryptedSlot[tokenId]);
    }

    /// @notice Plain slot after finalize. Reverts before that.
    function revealedSlot(uint256 tokenId) external view returns (uint16) {
        _requireOwned(tokenId);
        MaskuzaStorage storage $ = _maskuzaStorage();
        if (!$.revealed[tokenId]) revert RevealNotRequested();
        return $.clearSlot[tokenId];
    }

    /// @notice Whether `account` may use the current slot handle.
    function slotAllowed(uint256 tokenId, address account) external view returns (bool) {
        _requireOwned(tokenId);
        return SlotDraw.allowed(_maskuzaStorage().encryptedSlot[tokenId], account);
    }

    /// @notice Sealed chest until finalize. Then the pool art for the plain slot, or the hook, or the base URI.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        MaskuzaStorage storage $ = _maskuzaStorage();
        if (!$.revealed[tokenId]) return ArtPool.sealedUri(tokenId);
        string memory revealedUri = ArtPool.revealedUri(tokenId, $.clearSlot[tokenId]);
        if (bytes(revealedUri).length != 0) return revealedUri;
        if ($.uriHook != address(0)) {
            string memory hooked = IMaskuzaURI($.uriHook).tokenURI(tokenId);
            if (bytes(hooked).length != 0) return hooked;
        }
        return string.concat($.baseURI, tokenId.toString(), $.uriSuffix);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721CUpgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return interfaceId == type(IMaskuza).interfaceId || ERC721CUpgradeable.supportsInterface(interfaceId)
            || ERC2981Upgradeable.supportsInterface(interfaceId);
    }

    /// @notice Mint `quantity` masks to the caller. Payment stays in this contract.
    /// @param merkleProof GTD or whitelist proof. Ignored during public mint.
    function mint(uint256 quantity, bytes32[] calldata merkleProof) external payable nonReentrant whenNotPaused {
        MaskuzaStorage storage $ = _maskuzaStorage();
        Phase current = _currentPhase($);
        if (current == Phase.Closed) revert MintClosed();
        if (quantity == 0 || quantity > MINTS_PER_PHASE) revert InvalidQuantity();
        if ($.totalMinted + quantity > MAX_SUPPLY) revert SoldOut();
        if ($.mintedInPhase[current][msg.sender] + quantity > MINTS_PER_PHASE) revert PhaseLimitExceeded();
        if ($.mintedByWallet[msg.sender] + quantity > $.maxPerWallet) revert WalletCapExceeded();

        uint256 price = _price($, current);
        if (msg.value != price * quantity) revert IncorrectPayment();
        if (current == Phase.Gtd || current == Phase.Whitelist) {
            bytes32 root = current == Phase.Gtd ? $.gtdRoot : $.whitelistRoot;
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
            if (!MerkleProof.verifyCalldata(merkleProof, root, leaf)) revert NotOnMintList();
        }

        $.mintedInPhase[current][msg.sender] += quantity;
        $.mintedByWallet[msg.sender] += quantity;
        uint256 start = $.totalMinted;
        $.totalMinted = start + quantity;
        for (uint256 i = 0; i < quantity; ++i) {
            _mintOne(msg.sender, start + 1 + i);
        }
        emit Minted(msg.sender, quantity, msg.value);
    }

    /// @notice Mint `quantity` tokens to `to` for free. Ignores phase, price, and wallet caps.
    /// @dev Still stops at {MAX_SUPPLY}, and while the contract is paused. Uses the same mint path as {mint}.
    function ownerMint(address to, uint256 quantity) external onlyOwner nonReentrant whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (quantity == 0) revert InvalidQuantity();
        if (quantity > MAX_DRAW_PER_TX) revert DrawBatchTooLarge();
        MaskuzaStorage storage $ = _maskuzaStorage();
        if ($.totalMinted + quantity > MAX_SUPPLY) revert SoldOut();
        uint256 start = $.totalMinted;
        $.totalMinted = start + quantity;
        for (uint256 i = 0; i < quantity; ++i) {
            _mintOne(to, start + 1 + i);
        }
        emit OwnerMinted(to, quantity);
    }

    /// @notice Ask for this token's slot to be publicly decryptable. Only the holder. Does not change tokenURI.
    function reveal(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotHolder();
        MaskuzaStorage storage $ = _maskuzaStorage();
        if ($.revealRequested[tokenId] || $.revealed[tokenId]) revert AlreadyRevealed();
        $.revealRequested[tokenId] = true;
        $.encryptedSlot[tokenId] = SlotDraw.publish($.encryptedSlot[tokenId]);
        emit RevealRequested(tokenId, msg.sender, euint16.unwrap($.encryptedSlot[tokenId]));
    }

    /// @notice Store the plain slot once the KMS proof matches the published handle. Anyone may submit it.
    function finalizeReveal(uint256 tokenId, uint16 slot, bytes calldata proof) external {
        MaskuzaStorage storage $ = _maskuzaStorage();
        if (!$.revealRequested[tokenId]) revert RevealNotRequested();
        if ($.revealed[tokenId]) revert AlreadyRevealed();
        SlotDraw.verify($.encryptedSlot[tokenId], slot, proof);
        if (slot >= MAX_SUPPLY || $.slotUsed[slot]) revert SlotTaken();
        $.slotUsed[slot] = true;
        $.clearSlot[tokenId] = slot;
        $.revealed[tokenId] = true;
        emit RevealFinalized(tokenId, slot);
    }

    /// @notice Set the mint start. Zero closes minting. `pause` is the emergency stop.
    function setStartTime(uint64 startTime_) external onlyOwner {
        _maskuzaStorage().startTime = startTime_;
        emit StartTimeSet(startTime_);
    }

    /// @notice Set the price in wei for GTD, whitelist, or public. Zero is a free phase.
    function setPhasePrice(Phase phase_, uint256 price) external onlyOwner {
        if (phase_ == Phase.Closed) revert PhaseNotConfigurable();
        MaskuzaStorage storage $ = _maskuzaStorage();
        if (phase_ == Phase.Gtd) $.gtdPrice = price;
        else if (phase_ == Phase.Whitelist) $.whitelistPrice = price;
        else $.publicPrice = price;
        emit PhasePriceSet(phase_, price);
    }

    /// @notice Set how long GTD or whitelist lasts. Public has no end. Zero skips that phase.
    function setPhaseDuration(Phase phase_, uint64 duration) external onlyOwner {
        MaskuzaStorage storage $ = _maskuzaStorage();
        if (phase_ == Phase.Gtd) $.gtdDuration = duration;
        else if (phase_ == Phase.Whitelist) $.whitelistDuration = duration;
        else revert PhaseNotConfigurable();
        emit PhaseDurationSet(phase_, duration);
    }

    /// @notice Set the GTD or whitelist Merkle root.
    function setMerkleRoot(Phase phase_, bytes32 root) external onlyOwner {
        MaskuzaStorage storage $ = _maskuzaStorage();
        if (phase_ == Phase.Gtd) $.gtdRoot = root;
        else if (phase_ == Phase.Whitelist) $.whitelistRoot = root;
        else revert PhaseNotConfigurable();
        emit MerkleRootSet(phase_, root);
    }

    /// @notice Set the token cap across all phases. Each phase still allows only {MINTS_PER_PHASE}.
    function setMaxPerWallet(uint256 maxPerWallet_) external onlyOwner {
        _maskuzaStorage().maxPerWallet = maxPerWallet_;
        emit MaxPerWalletSet(maxPerWallet_);
    }

    /// @notice Prefix for revealed metadata, for example an IPFS or Arweave directory.
    function setBaseURI(string calldata baseURI_) external onlyOwner {
        _maskuzaStorage().baseURI = baseURI_;
        emit BaseURISet(baseURI_);
    }

    /// @notice Store pool PNGs and metadata at slots. A later call replaces a slot until {lockRevealedArt}.
    /// @dev Each PNG must be 100 by 100. Slots are 0..665. The token name is not stored here.
    function setRevealedArt(
        uint256[] calldata slots,
        bytes[] calldata pngs,
        string[] calldata descriptions,
        string[][] calldata traitTypes,
        string[][] calldata values
    ) external onlyOwner {
        ArtPool.setRevealed(slots, pngs, descriptions, traitTypes, values);
    }

    /// @notice Freeze revealed art and metadata. Reverts until all 666 slots are uploaded. Further uploads revert.
    /// @dev Never called by the deploy script. Run script/LockRevealedArt.s.sol manually when ready.
    function lockRevealedArt() external onlyOwner {
        ArtPool.lock();
        emit RevealedArtLocked();
    }

    function revealedArtLocked() external view returns (bool) {
        return ArtPool.locked();
    }

    /// @notice Distinct pool slots uploaded so far (0..666).
    function revealedArtUploaded() external view returns (uint256) {
        return ArtPool.uploaded();
    }

    /// @notice Pool record for `slot`. Public. It does not say which token receives the slot.
    function poolArt(uint256 slot) external view returns (address png, string memory description, uint256 attributes) {
        return ArtPool.poolArt(slot);
    }

    function poolAttribute(uint256 slot, uint256 index)
        external
        view
        returns (string memory traitType, string memory value)
    {
        return ArtPool.poolAttribute(slot, index);
    }

    /// @notice Store the 100 by 100 sealed PNG in a new bytecode contract.
    function setSealedArt(bytes calldata png) external onlyOwner {
        emit SealedArtSet(ArtPool.writeSealed(png), png.length);
    }

    /// @notice Optional contract that can replace the base URI for a revealed token. Zero clears it.
    function setURIHook(address uriHook_) external onlyOwner {
        if (uriHook_ != address(0) && uriHook_.code.length == 0) revert HookNotContract();
        _maskuzaStorage().uriHook = uriHook_;
        emit URIHookSet(uriHook_);
    }

    /// @notice Suffix appended after the token id, for example `.json`. Empty leaves the id bare.
    function setURISuffix(string calldata uriSuffix_) external onlyOwner {
        _maskuzaStorage().uriSuffix = uriSuffix_;
        emit URISuffixSet(uriSuffix_);
    }

    /// @notice Set the account that receives the 5% royalty. The rate does not change.
    function setRoyaltyReceiver(address receiver) external onlyOwner {
        if (receiver == address(0)) revert ZeroAddress();
        _setDefaultRoyalty(receiver, ROYALTY_BPS);
        emit RoyaltyReceiverSet(receiver, ROYALTY_BPS);
    }

    /// @notice Allow `operator` to transfer tokens for holders.
    /// @dev Selects the whitelist ruleset. Wallet-to-wallet transfers stay allowed.
    function whitelistOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        address validator = getTransferValidator();
        ILimitBreakTransferValidator transferValidator = ILimitBreakTransferValidator(validator);
        transferValidator.setRulesetOfCollection(
            address(this), RULESET_ID_WHITELIST, address(0), FLAG_GLOBAL_CUSTOM_LIST_SUPPLEMENTS_DEFAULT_LIST, 0
        );
        MaskuzaStorage storage $ = _maskuzaStorage();
        uint48 listId = $.operatorWhitelistId;
        if (listId == 0) {
            listId = transferValidator.createList("MASKUZA operators");
            $.operatorWhitelistId = listId;
            transferValidator.applyListToCollection(address(this), listId);
        }
        address[] memory accounts = new address[](1);
        accounts[0] = operator;
        transferValidator.addAccountsToList(listId, LIST_TYPE_WHITELIST, accounts);
        emit OperatorWhitelisted(validator, listId, operator);
    }

    /// @notice Pause new mints. Reveals and withdrawals keep working.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume minting.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Send the full contract balance to `to`.
    function withdraw(address to) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        if (amount > 0) {
            emit Withdrawn(to, amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert WithdrawFailed();
            return;
        }
        revert NothingToWithdraw();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _msgSender() internal view override(ERC721CUpgradeable, ContextUpgradeable) returns (address) {
        return ERC721CUpgradeable._msgSender();
    }

    function _msgData() internal view override(ERC721CUpgradeable, ContextUpgradeable) returns (bytes calldata) {
        return ERC721CUpgradeable._msgData();
    }

    function _contextSuffixLength() internal view override(ERC721CUpgradeable, ContextUpgradeable) returns (uint256) {
        return ERC721CUpgradeable._contextSuffixLength();
    }

    function _requireCallerIsContractOwner() internal view override {
        _checkOwner();
    }

    /// @dev Plain `_mint` with no receiver callback, so smart-account and contract wallets can always mint.
    function _mintOne(address to, uint256 tokenId) internal {
        _mint(to, tokenId);
    }

    /// @dev Mint draws a fresh encrypted slot. Later transfers grant the new owner the same handle.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (to == address(0)) return from;
        MaskuzaStorage storage $ = _maskuzaStorage();
        if (from == address(0)) {
            $.encryptedSlot[tokenId] = SlotDraw.assign($.roundKeys, tokenId - 1, to);
            return from;
        }
        SlotDraw.grant($.encryptedSlot[tokenId], to);
    }

    function _currentPhase(MaskuzaStorage storage $) internal view returns (Phase) {
        uint64 start = $.startTime;
        if (start == 0 || block.timestamp < start) return Phase.Closed;
        uint256 gtdEnd = uint256(start) + $.gtdDuration;
        if (block.timestamp < gtdEnd) return Phase.Gtd;
        uint256 whitelistEnd = gtdEnd + $.whitelistDuration;
        if (block.timestamp < whitelistEnd) return Phase.Whitelist;
        return Phase.Public;
    }

    function _price(MaskuzaStorage storage $, Phase phase_) internal view returns (uint256) {
        if (phase_ == Phase.Gtd) return $.gtdPrice;
        if (phase_ == Phase.Whitelist) return $.whitelistPrice;
        return $.publicPrice;
    }

    function _maskuzaStorage() private pure returns (MaskuzaStorage storage $) {
        assembly {
            $.slot := MASKUZA_STORAGE_LOCATION
        }
    }
}
