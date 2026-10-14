// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {FHE} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {euint64, eaddress, ebool, externalEuint64} from "encrypted-types/EncryptedTypes.sol";
import {IMaskuza} from "./interfaces/IMaskuza.sol";
import {MarketOrders, MarketTypes} from "./MarketOrders.sol";
import {SaleSplit} from "./SaleSplit.sol";

/// @title MaskuzaMarketplace
/// @notice Listings, offers, and sealed-bid auctions for one MASKUZA collection.
/// @dev UUPS proxy. Order logic lives in {MarketOrders} and runs by delegatecall.
///      Listings are non-custodial. Auctions escrow the token. Every sale pays at least 5% royalty.
///      A price cannot be a fourth indexed topic. ETH liabilities are {accountedEth}.
contract MaskuzaMarketplace is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IERC721Receiver
{
    // keccak256(abi.encode(uint256(keccak256("maskuza.marketplace")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MARKETPLACE_STORAGE_LOCATION =
        0xc87f49dd6db1bccfab4d055db07f78b24a6b9866f4e5af289afc7dac8b273d00;

    uint256 public constant BPS = SaleSplit.BPS;
    uint96 public constant ROYALTY_BPS = 500;
    uint96 public constant MAX_FEE_BPS = 1000;
    uint256 public constant MIN_PRICE = 20;
    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 14 days;
    uint64 public constant MAX_OFFER_DURATION = 180 days;
    uint64 public constant SETTLEMENT_GRACE = 3 days;
    uint256 public constant MAX_BATCH = 20;
    uint256 public constant MAX_PAGE = 50;

    error ZeroAddress();
    error UnsupportedCollection();
    error FeeTooHigh();
    error NotListed();
    error NotSeller();
    error NotOwner();
    error NotApproved();
    error WrongPayment();
    error ZeroPrice();
    error PriceTooLow();
    error PriceTooHigh();
    error AlreadyListed();
    error ListingExpired();
    error ListingStale();
    error ListingStillValid();
    error TokenAlreadyEscrowed();
    error AuctionNotLive();
    error AuctionNotStarted();
    error AuctionEnded();
    error AuctionStillRunning();
    error ZeroDeposit();
    error DepositTooLarge();
    error SellerCannotBid();
    error DurationOutOfRange();
    error BidsExist();
    error DecryptionAlreadyRequested();
    error DecryptionNotRequested();
    error AlreadySettled();
    error NothingToRefund();
    error AuctionOpen();
    error GraceNotElapsed();
    error DepositShortfall();
    error NothingToWithdraw();
    error WithdrawFailed();
    error UnknownAuction();
    error DirectTransfersDisabled();
    error DirectEthDisabled();
    error RoyaltyNotPaid();
    error WethNotSet();
    error WethChangeBlocked();
    error WethTransferFailed();
    error OfferInactive();
    error OfferExpired();
    error NotBuyer();
    error BuyerIsSeller();
    error WrongToken();
    error BatchTooLarge();
    error ArrayLengthMismatch();

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price, uint64 expiry);
    event ListingUpdated(uint256 indexed tokenId, address indexed seller, uint256 price, uint64 expiry);
    event ListingCancelled(uint256 indexed tokenId, address indexed seller);
    event ListingInvalidated(uint256 indexed tokenId, address indexed seller);
    event Sale(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint256 price,
        uint256 sellerProceeds,
        uint256 fee,
        uint256 royalty
    );
    event OfferMade(
        uint256 indexed offerId,
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 price,
        uint64 expiry,
        bool collectionOffer,
        bool weth
    );
    event OfferCancelled(uint256 indexed offerId, uint256 indexed tokenId, address indexed buyer);
    event OfferAccepted(
        uint256 indexed offerId, uint256 indexed tokenId, address indexed buyer, address seller, uint256 price
    );
    event AuctionCreated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed seller,
        uint64 reservePrice,
        uint64 startTime,
        uint64 endTime
    );
    event BidPlaced(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 addedDeposit,
        uint256 depositTotal
    );
    event SettlementRequested(uint256 indexed auctionId, bytes32 highestBidHandle, bytes32 winningAddressHandle);
    event AuctionSettled(
        uint256 indexed auctionId, uint256 indexed tokenId, address indexed winner, address seller, uint64 clearingPrice
    );
    event AuctionCancelled(uint256 indexed auctionId);
    event AuctionUnwound(uint256 indexed auctionId);
    event BidRefunded(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);
    event FeeUpdated(address indexed feeRecipient, uint96 feeBps);
    event WethSet(address indexed weth);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy for one MASKUZA collection.
    /// @param feeBps_ Marketplace fee in basis points. Cannot exceed {MAX_FEE_BPS}.
    function initialize(address maskuza_, address feeRecipient_, uint96 feeBps_) external initializer {
        if (maskuza_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (!IERC165(maskuza_).supportsInterface(type(IMaskuza).interfaceId)) revert UnsupportedCollection();
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig());

        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        $.maskuza = IERC721(maskuza_);
        $.royaltySource = IERC2981(maskuza_);
        $.feeRecipient = feeRecipient_;
        $.feeBps = feeBps_;
    }

    /// @notice Accept ETH only from the configured WETH contract, when an offer is unwrapped.
    receive() external payable {
        if (msg.sender != _marketplaceStorage().weth) revert DirectEthDisabled();
    }

    function maskuza() external view returns (IERC721) {
        return _marketplaceStorage().maskuza;
    }

    function feeRecipient() external view returns (address) {
        return _marketplaceStorage().feeRecipient;
    }

    function feeBps() external view returns (uint96) {
        return _marketplaceStorage().feeBps;
    }

    function weth() external view returns (address) {
        return _marketplaceStorage().weth;
    }

    function nextAuctionId() external view returns (uint256) {
        return _marketplaceStorage().nextAuctionId;
    }

    function nextOfferId() external view returns (uint256) {
        return _marketplaceStorage().nextOfferId;
    }

    /// @notice ETH that should sit in this contract: credits, auction deposits, and ETH offer escrow.
    /// @dev Auction proceeds are credited before the winner's deposit is reduced, and that amount is subtracted here.
    function accountedEth() external view returns (uint256) {
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        return $.pendingTotal + $.depositTotal + $.ethOfferEscrow - $.auctionProceedsCredited;
    }

    function wethEscrow() external view returns (uint256) {
        return _marketplaceStorage().wethOfferEscrow;
    }

    function ethOfferEscrow() external view returns (uint256) {
        return _marketplaceStorage().ethOfferEscrow;
    }

    function listings(uint256 tokenId) external view returns (address seller, uint256 price, uint64 expiry) {
        MarketTypes.Listing memory listing = _marketplaceStorage().listings[tokenId];
        return (listing.seller, listing.price, listing.expiry);
    }

    function activeListingCount() external view returns (uint256) {
        return _marketplaceStorage().activeListingIds.length;
    }

    /// @notice Page of listed token ids. `limit` is capped at {MAX_PAGE}.
    function activeListings(uint256 offset, uint256 limit) external view returns (uint256[] memory tokenIds) {
        return MarketOrders.page(_marketplaceStorage().activeListingIds, offset, limit);
    }

    function tokenAuction(uint256 tokenId) external view returns (uint256) {
        return _marketplaceStorage().tokenAuction[tokenId];
    }

    function deposits(uint256 auctionId, address bidder) external view returns (uint256) {
        return _marketplaceStorage().deposits[auctionId][bidder];
    }

    function pendingWithdrawals(address account) external view returns (uint256) {
        return _marketplaceStorage().pendingWithdrawals[account];
    }

    function offer(uint256 offerId)
        external
        view
        returns (
            address buyer,
            uint256 tokenId,
            uint128 price,
            uint64 expiry,
            bool collectionOffer,
            bool usesWeth,
            bool active
        )
    {
        MarketTypes.Offer memory item = _marketplaceStorage().offers[offerId];
        return (item.buyer, item.tokenId, item.price, item.expiry, item.collectionOffer, item.weth, item.active);
    }

    function tokenOfferCount(uint256 tokenId) external view returns (uint256) {
        return _marketplaceStorage().tokenOfferIds[tokenId].length;
    }

    /// @notice Offer ids for `tokenId`, including inactive ids. Read {offer} for `active`.
    function tokenOffers(uint256 tokenId, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        return MarketOrders.page(_marketplaceStorage().tokenOfferIds[tokenId], offset, limit);
    }

    function collectionOfferCount() external view returns (uint256) {
        return _marketplaceStorage().collectionOfferIds.length;
    }

    /// @notice Collection offer ids, including inactive ids.
    function collectionOffers(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        return MarketOrders.page(_marketplaceStorage().collectionOfferIds, offset, limit);
    }

    /// @notice Last sale price and how many sales this marketplace recorded for `tokenId`.
    function saleStats(uint256 tokenId) external view returns (uint128 lastPrice, uint64 saleCount) {
        MarketTypes.TokenSaleStats memory stats = _marketplaceStorage().saleStats[tokenId];
        return (stats.lastPrice, stats.saleCount);
    }

    /// @notice List `tokenId` with no expiry. The token stays in the caller's wallet.
    function list(uint256 tokenId, uint256 price) external nonReentrant whenNotPaused {
        MarketOrders.openListing(_marketplaceStorage(), tokenId, price, 0);
    }

    /// @notice List `tokenId` until `expiry`. Zero `expiry` does not expire.
    function list(uint256 tokenId, uint256 price, uint64 expiry) external nonReentrant whenNotPaused {
        MarketOrders.openListing(_marketplaceStorage(), tokenId, price, expiry);
    }

    /// @notice List up to {MAX_BATCH} tokens. Array lengths must match.
    function batchList(uint256[] calldata tokenIds, uint256[] calldata prices, uint64[] calldata expiries)
        external
        nonReentrant
        whenNotPaused
    {
        uint256 n = tokenIds.length;
        if (n == 0 || n > MAX_BATCH) revert BatchTooLarge();
        if (prices.length != n || expiries.length != n) revert ArrayLengthMismatch();
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        for (uint256 i = 0; i < n; ++i) {
            MarketOrders.openListing($, tokenIds[i], prices[i], expiries[i]);
        }
    }

    /// @notice Change the price and expiry of your listing.
    function updateListing(uint256 tokenId, uint256 price, uint64 expiry) external nonReentrant whenNotPaused {
        MarketOrders.changeListing(_marketplaceStorage(), tokenId, price, expiry);
    }

    /// @notice Cancel your listing. The token was never escrowed.
    function cancelListing(uint256 tokenId) external nonReentrant {
        MarketOrders.closeListing(_marketplaceStorage(), tokenId);
    }

    /// @notice Clear a listing that is expired, sold out from under the seller, or no longer approved.
    function invalidateListing(uint256 tokenId) external nonReentrant {
        MarketOrders.dropListing(_marketplaceStorage(), tokenId);
    }

    /// @notice Buy a listing. `msg.value` must equal the price.
    function buy(uint256 tokenId) external payable nonReentrant whenNotPaused {
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        if (msg.value != MarketOrders.quote($, tokenId)) revert WrongPayment();
        MarketOrders.buyOne($, tokenId);
    }

    /// @notice Buy up to {MAX_BATCH} listings. `msg.value` must equal the sum of the prices.
    function batchBuy(uint256[] calldata tokenIds) external payable nonReentrant whenNotPaused {
        uint256 n = tokenIds.length;
        if (n == 0 || n > MAX_BATCH) revert BatchTooLarge();
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            total += MarketOrders.quote($, tokenIds[i]);
        }
        if (msg.value != total) revert WrongPayment();
        for (uint256 i = 0; i < n; ++i) {
            MarketOrders.buyOne($, tokenIds[i]);
        }
    }

    /// @notice Escrow ETH for an offer on `tokenId`, or on any token when `collectionOffer` is true.
    function makeOffer(uint256 tokenId, uint128 price, uint64 expiry, bool collectionOffer)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        MarketOrders.openOffer(_marketplaceStorage(), tokenId, price, expiry, collectionOffer, false);
    }

    /// @notice Escrow WETH for an offer. The caller approves this contract for `price` first.
    function makeOfferWeth(uint256 tokenId, uint128 price, uint64 expiry, bool collectionOffer)
        external
        nonReentrant
        whenNotPaused
    {
        MarketOrders.openOffer(_marketplaceStorage(), tokenId, price, expiry, collectionOffer, true);
    }

    /// @notice Cancel your offer, or anyone's offer after it expires. Escrow returns to the buyer.
    function cancelOffer(uint256 offerId) external nonReentrant {
        MarketOrders.closeOffer(_marketplaceStorage(), offerId);
    }

    /// @notice Accept an offer by delivering `tokenId`.
    function acceptOffer(uint256 offerId, uint256 tokenId) external nonReentrant whenNotPaused {
        MarketOrders.fillOffer(_marketplaceStorage(), offerId, tokenId);
    }

    /// @notice Escrow `tokenId` for a sealed-bid auction. Pass `startTime` zero to start now.
    function createAuction(uint256 tokenId, uint64 reservePrice, uint64 startTime, uint64 duration)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 auctionId)
    {
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert DurationOutOfRange();
        if (block.timestamp > type(uint64).max) revert DurationOutOfRange();
        if (startTime == 0) startTime = uint64(block.timestamp);
        if (startTime < block.timestamp) revert AuctionNotStarted();
        if (startTime > type(uint64).max - duration) revert DurationOutOfRange();
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        if ($.listings[tokenId].price != 0 || $.tokenAuction[tokenId] != 0) revert TokenAlreadyEscrowed();

        auctionId = ++$.nextAuctionId;
        uint64 endTime = startTime + duration;
        MarketTypes.Auction storage a = $.auctions[auctionId];
        a.seller = msg.sender;
        a.tokenId = tokenId;
        a.reservePrice = reservePrice;
        a.startTime = startTime;
        a.endTime = endTime;
        a.live = true;
        $.tokenAuction[tokenId] = auctionId;
        emit AuctionCreated(auctionId, tokenId, msg.sender, reservePrice, startTime, endTime);
        $.maskuza.transferFrom(msg.sender, address(this), tokenId);
    }

    /// @notice Cancel an auction that has no bids.
    function cancelAuction(uint256 auctionId) external nonReentrant {
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        MarketTypes.Auction storage a = $.auctions[auctionId];
        if (!a.live) revert AuctionNotLive();
        if (a.seller != msg.sender) revert NotSeller();
        if (a.bidderCount != 0) revert BidsExist();
        a.cancelled = true;
        emit AuctionCancelled(auctionId);
        _releaseToken(a, auctionId);
    }

    /// @notice Submit an encrypted bid. `msg.value` is added to that bidder's deposit.
    function bid(uint256 auctionId, externalEuint64 encryptedAmount, bytes calldata inputProof)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        MarketTypes.Auction storage a = $.auctions[auctionId];
        if (!a.live) revert AuctionNotLive();
        if (block.timestamp < a.startTime) revert AuctionNotStarted();
        if (block.timestamp >= a.endTime) revert AuctionEnded();
        if (msg.sender == a.seller) revert SellerCannotBid();
        if (msg.value == 0) revert ZeroDeposit();

        uint256 newDeposit = $.deposits[auctionId][msg.sender] + msg.value;
        if (newDeposit > type(uint64).max) revert DepositTooLarge();
        uint64 depositCap = uint64(newDeposit);
        if ($.deposits[auctionId][msg.sender] == 0) a.bidderCount += 1;
        $.deposits[auctionId][msg.sender] = newDeposit;
        $.depositTotal += msg.value;

        euint64 offered = FHE.fromExternal(encryptedAmount, inputProof);
        (euint64 storedBid, ebool eligible) = _storeBid(auctionId, msg.sender, offered, depositCap, a.reservePrice);
        _considerHighest(a, storedBid, eligible, msg.sender);
        emit BidPlaced(auctionId, a.tokenId, msg.sender, msg.value, newDeposit);
    }

    /// @notice After the end time, make the winning bid decryptable. No eligible bid returns the token.
    function requestSettlement(uint256 auctionId) external nonReentrant {
        MarketTypes.Auction storage a = _marketplaceStorage().auctions[auctionId];
        if (!a.live) revert AuctionNotLive();
        if (block.timestamp < a.endTime) revert AuctionStillRunning();
        if (a.bidderCount == 0 || !FHE.isInitialized(a.highestBid)) {
            a.settled = true;
            emit AuctionSettled(auctionId, a.tokenId, address(0), a.seller, 0);
            _releaseToken(a, auctionId);
            return;
        }
        if (a.decryptionRequested) revert DecryptionAlreadyRequested();
        a.decryptionRequested = true;
        a.highestBid = FHE.makePubliclyDecryptable(a.highestBid);
        a.winningAddress = FHE.makePubliclyDecryptable(a.winningAddress);
        emit SettlementRequested(auctionId, FHE.toBytes32(a.highestBid), FHE.toBytes32(a.winningAddress));
    }

    /// @notice Check the decryption proof, pay the sale, and deliver the token.
    function finalizeAuction(uint256 auctionId, uint64 price, address winner, bytes calldata proof)
        external
        nonReentrant
    {
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        MarketTypes.Auction storage a = $.auctions[auctionId];
        if (!a.live) revert AuctionNotLive();
        if (!a.decryptionRequested) revert DecryptionNotRequested();
        if (a.settled || a.cancelled) revert AlreadySettled();

        bytes32[] memory handles = new bytes32[](2);
        handles[0] = FHE.toBytes32(a.highestBid);
        handles[1] = FHE.toBytes32(a.winningAddress);
        FHE.checkSignatures(handles, abi.encode(price, winner), proof);

        if (winner == address(0) || price == 0) {
            a.settled = true;
            emit AuctionSettled(auctionId, a.tokenId, address(0), a.seller, 0);
            _releaseToken(a, auctionId);
            return;
        }
        if ($.deposits[auctionId][winner] < price) revert DepositShortfall();

        a.settled = true;
        a.winner = winner;
        a.clearingPrice = price;
        emit AuctionSettled(auctionId, a.tokenId, winner, a.seller, price);
        MarketOrders.creditSale($, a.tokenId, winner, a.seller, price, true);
        _releaseToken(a, auctionId, winner);
    }

    /// @notice Return the token and allow full refunds after the settlement grace period.
    function unwindAuction(uint256 auctionId) external nonReentrant {
        MarketTypes.Auction storage a = _marketplaceStorage().auctions[auctionId];
        if (!a.live) revert AuctionNotLive();
        if (block.timestamp < uint256(a.endTime) + SETTLEMENT_GRACE) revert GraceNotElapsed();
        a.cancelled = true;
        emit AuctionUnwound(auctionId);
        _releaseToken(a, auctionId);
    }

    /// @notice Pull your deposit back after the auction is settled or unwound.
    function refundBid(uint256 auctionId) external nonReentrant {
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        MarketTypes.Auction storage a = $.auctions[auctionId];
        if (a.live || (!a.settled && !a.cancelled)) revert AuctionOpen();
        uint256 deposit = $.deposits[auctionId][msg.sender];
        if (deposit == 0) revert NothingToRefund();
        $.deposits[auctionId][msg.sender] = 0;
        $.depositTotal -= deposit;
        uint256 payout = deposit;
        if (a.settled && msg.sender == a.winner) {
            if (deposit < a.clearingPrice) revert DepositShortfall();
            payout = deposit - a.clearingPrice;
            $.auctionProceedsCredited -= a.clearingPrice;
        }
        if (payout != 0) {
            $.pendingWithdrawals[msg.sender] += payout;
            $.pendingTotal += payout;
        }
        emit BidRefunded(auctionId, msg.sender, payout);
    }

    /// @notice Withdraw ETH credited to the caller.
    function withdraw() external nonReentrant {
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        uint256 amount = $.pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        $.pendingWithdrawals[msg.sender] = 0;
        $.pendingTotal -= amount;
        emit Withdrawal(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
    }

    function auctionInfo(uint256 auctionId)
        external
        view
        returns (
            address seller,
            uint256 tokenId,
            uint64 reservePrice,
            uint64 startTime,
            uint64 endTime,
            uint32 bidderCount,
            bool live,
            bool decryptionRequested,
            bool settled,
            bool cancelled,
            address winner,
            uint64 clearingPrice
        )
    {
        MarketTypes.Auction storage a = _marketplaceStorage().auctions[auctionId];
        if (a.seller == address(0)) revert UnknownAuction();
        return (
            a.seller,
            a.tokenId,
            a.reservePrice,
            a.startTime,
            a.endTime,
            a.bidderCount,
            a.live,
            a.decryptionRequested,
            a.settled,
            a.cancelled,
            a.winner,
            a.clearingPrice
        );
    }

    function auctionCiphertexts(uint256 auctionId) external view returns (bytes32 highestBid, bytes32 winningAddress) {
        MarketTypes.Auction storage a = _marketplaceStorage().auctions[auctionId];
        if (a.seller == address(0)) revert UnknownAuction();
        return (FHE.toBytes32(a.highestBid), FHE.toBytes32(a.winningAddress));
    }

    function encryptedBid(uint256 auctionId, address bidder) external view returns (bytes32) {
        return FHE.toBytes32(_marketplaceStorage().bids[auctionId][bidder]);
    }

    /// @notice Set the fee recipient and fee. Credits already recorded stay where they are.
    function setFee(address recipient, uint96 bps) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        $.feeRecipient = recipient;
        $.feeBps = bps;
        emit FeeUpdated(recipient, bps);
    }

    /// @notice Set the WETH contract used for offers. Reverts while WETH offers are still escrowed.
    function setWeth(address weth_) external onlyOwner {
        if (weth_ == address(0) || weth_.code.length == 0) revert WethNotSet();
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        if ($.wethOfferEscrow != 0) revert WethChangeBlocked();
        $.weth = weth_;
        emit WethSet(weth_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Direct transfers are rejected. Auctions pull the token themselves.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert DirectTransfersDisabled();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _storeBid(uint256 auctionId, address bidder, euint64 offered, uint64 deposit, uint64 reserve)
        internal
        returns (euint64 storedBid, ebool eligible)
    {
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        euint64 previous = $.bids[auctionId][bidder];
        if (FHE.isInitialized(previous)) {
            ebool raised = FHE.gt(offered, previous);
            euint64 candidate = FHE.select(raised, offered, previous);
            eligible = _eligible(candidate, deposit, reserve);
            storedBid = FHE.select(eligible, candidate, previous);
        } else {
            eligible = _eligible(offered, deposit, reserve);
            storedBid = FHE.select(eligible, offered, FHE.asEuint64(uint64(0)));
        }
        storedBid = FHE.allow(FHE.allowThis(storedBid), bidder);
        $.bids[auctionId][bidder] = storedBid;
    }

    function _eligible(euint64 amount, uint64 deposit, uint64 reserve) internal returns (ebool) {
        ebool withinDeposit = FHE.le(amount, deposit);
        ebool meetsReserve = FHE.ge(amount, reserve);
        ebool meetsFloor = FHE.ge(amount, uint64(MIN_PRICE));
        ebool positive = FHE.gt(amount, uint64(0));
        return FHE.and(meetsFloor, FHE.and(positive, FHE.and(withinDeposit, meetsReserve)));
    }

    function _considerHighest(MarketTypes.Auction storage a, euint64 storedBid, ebool eligible, address bidder)
        internal
    {
        eaddress bidderCt = _blindAddress(bidder);
        if (!FHE.isInitialized(a.highestBid)) {
            a.highestBid = FHE.select(eligible, storedBid, FHE.asEuint64(uint64(0)));
            a.winningAddress = FHE.select(eligible, bidderCt, _blindAddress(address(0)));
        } else {
            ebool beats = FHE.and(eligible, FHE.lt(a.highestBid, storedBid));
            a.highestBid = FHE.select(beats, storedBid, a.highestBid);
            a.winningAddress = FHE.select(beats, bidderCt, a.winningAddress);
        }
        a.highestBid = FHE.allowThis(a.highestBid);
        a.winningAddress = FHE.allowThis(a.winningAddress);
    }

    /// @dev Stores the bidder as a coprocessor ciphertext.
    function _blindAddress(address account) internal returns (eaddress) {
        ebool control = FHE.or(FHE.asEbool(true), FHE.randEbool());
        return FHE.select(control, FHE.asEaddress(account), FHE.asEaddress(address(0)));
    }

    function _releaseToken(MarketTypes.Auction storage a, uint256 auctionId) internal {
        _releaseToken(a, auctionId, a.seller);
    }

    function _releaseToken(MarketTypes.Auction storage a, uint256 auctionId, address to) internal {
        MarketTypes.MarketplaceStorage storage $ = _marketplaceStorage();
        a.live = false;
        uint256 tokenId = a.tokenId;
        if ($.tokenAuction[tokenId] == auctionId) $.tokenAuction[tokenId] = 0;
        $.maskuza.transferFrom(address(this), to, tokenId);
    }

    function _marketplaceStorage() private pure returns (MarketTypes.MarketplaceStorage storage $) {
        assembly {
            $.slot := MARKETPLACE_STORAGE_LOCATION
        }
    }
}
