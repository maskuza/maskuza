// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {euint64, eaddress} from "encrypted-types/EncryptedTypes.sol";
import {SaleSplit} from "./SaleSplit.sol";

/// @notice WETH pulled and unwrapped for offers.
interface IWETH {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function withdraw(uint256 amount) external;
}

/// @notice Shared marketplace types. Append-only inside {MarketplaceStorage}.
library MarketTypes {
    struct Auction {
        address seller;
        uint256 tokenId;
        uint64 reservePrice;
        uint64 startTime;
        uint64 endTime;
        uint32 bidderCount;
        bool live;
        bool decryptionRequested;
        bool settled;
        bool cancelled;
        address winner;
        uint64 clearingPrice;
        euint64 highestBid;
        eaddress winningAddress;
    }

    struct Listing {
        address seller;
        uint256 price;
        uint64 expiry;
    }

    struct Offer {
        address buyer;
        uint256 tokenId;
        uint128 price;
        uint64 expiry;
        bool collectionOffer;
        bool weth;
        bool active;
    }

    struct TokenSaleStats {
        uint128 lastPrice;
        uint64 saleCount;
    }

    /// @custom:storage-location erc7201:maskuza.marketplace
    struct MarketplaceStorage {
        IERC721 maskuza;
        IERC2981 royaltySource;
        address feeRecipient;
        uint96 feeBps;
        uint256 nextAuctionId;
        mapping(uint256 tokenId => Listing) listings;
        mapping(uint256 auctionId => Auction) auctions;
        mapping(uint256 tokenId => uint256 auctionId) tokenAuction;
        mapping(uint256 auctionId => mapping(address bidder => uint256 deposit)) deposits;
        mapping(uint256 auctionId => mapping(address bidder => euint64 bid)) bids;
        mapping(address account => uint256 amount) pendingWithdrawals;
        address weth;
        uint256 pendingTotal;
        uint256 depositTotal;
        uint256 ethOfferEscrow;
        uint256 wethOfferEscrow;
        uint256 auctionProceedsCredited;
        uint256 nextOfferId;
        uint256[] activeListingIds;
        mapping(uint256 tokenId => uint256 indexPlusOne) listingPos;
        mapping(uint256 offerId => Offer) offers;
        mapping(uint256 tokenId => uint256[] ids) tokenOfferIds;
        uint256[] collectionOfferIds;
        mapping(uint256 tokenId => TokenSaleStats) saleStats;
    }
}

/// @title MarketOrders
/// @notice Listings, offers, and sale splits. Called with delegatecall from the marketplace.
library MarketOrders {
    using MarketTypes for MarketTypes.MarketplaceStorage;

    uint256 internal constant BPS = SaleSplit.BPS;
    uint96 internal constant ROYALTY_BPS = 500;
    uint256 internal constant MIN_PRICE = 20;
    uint64 internal constant MAX_OFFER_DURATION = 180 days;
    uint256 internal constant MAX_PAGE = 50;

    error NotListed();
    error NotSeller();
    error NotOwner();
    error NotApproved();
    error ZeroPrice();
    error PriceTooLow();
    error PriceTooHigh();
    error AlreadyListed();
    error ListingExpired();
    error ListingStale();
    error ListingStillValid();
    error TokenAlreadyEscrowed();
    error WrongPayment();
    error RoyaltyNotPaid();
    error WethNotSet();
    error WethTransferFailed();
    error OfferInactive();
    error OfferExpired();
    error NotBuyer();
    error BuyerIsSeller();
    error WrongToken();

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

    function openListing(MarketTypes.MarketplaceStorage storage $, uint256 tokenId, uint256 price, uint64 expiry)
        public
    {
        _checkPrice(price);
        _checkExpiry(expiry);
        if ($.listings[tokenId].price != 0) revert AlreadyListed();
        if ($.tokenAuction[tokenId] != 0) revert TokenAlreadyEscrowed();
        if ($.maskuza.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (!_approved($, msg.sender, tokenId)) revert NotApproved();
        $.listings[tokenId] = MarketTypes.Listing(msg.sender, price, expiry);
        $.listingPos[tokenId] = $.activeListingIds.length + 1;
        $.activeListingIds.push(tokenId);
        emit Listed(tokenId, msg.sender, price, expiry);
    }

    function changeListing(MarketTypes.MarketplaceStorage storage $, uint256 tokenId, uint256 price, uint64 expiry)
        public
    {
        _checkPrice(price);
        MarketTypes.Listing storage listing = $.listings[tokenId];
        if (listing.price == 0) revert NotListed();
        if (listing.seller != msg.sender) revert NotSeller();
        if (!_fillable($, tokenId, listing.seller, listing.expiry)) revert ListingStale();
        _checkExpiry(expiry);
        listing.price = price;
        listing.expiry = expiry;
        emit ListingUpdated(tokenId, msg.sender, price, expiry);
    }

    function closeListing(MarketTypes.MarketplaceStorage storage $, uint256 tokenId) public {
        MarketTypes.Listing memory listing = $.listings[tokenId];
        if (listing.price == 0) revert NotListed();
        if (listing.seller != msg.sender) revert NotSeller();
        _clearListing($, tokenId);
        emit ListingCancelled(tokenId, listing.seller);
    }

    function dropListing(MarketTypes.MarketplaceStorage storage $, uint256 tokenId) public {
        MarketTypes.Listing memory listing = $.listings[tokenId];
        if (listing.price == 0) revert NotListed();
        if (_fillable($, tokenId, listing.seller, listing.expiry)) revert ListingStillValid();
        _clearListing($, tokenId);
        emit ListingInvalidated(tokenId, listing.seller);
    }

    function quote(MarketTypes.MarketplaceStorage storage $, uint256 tokenId) public view returns (uint256 price) {
        MarketTypes.Listing memory listing = $.listings[tokenId];
        if (listing.price == 0) revert NotListed();
        if (listing.expiry != 0 && block.timestamp >= listing.expiry) revert ListingExpired();
        if (msg.sender == listing.seller) revert BuyerIsSeller();
        if ($.maskuza.ownerOf(tokenId) != listing.seller || !_approved($, listing.seller, tokenId)) {
            revert ListingStale();
        }
        return listing.price;
    }

    function buyOne(MarketTypes.MarketplaceStorage storage $, uint256 tokenId) public {
        MarketTypes.Listing memory listing = $.listings[tokenId];
        if (listing.price == 0) revert NotListed();
        if (listing.expiry != 0 && block.timestamp >= listing.expiry) revert ListingExpired();
        if (msg.sender == listing.seller) revert BuyerIsSeller();
        if ($.maskuza.ownerOf(tokenId) != listing.seller || !_approved($, listing.seller, tokenId)) {
            revert ListingStale();
        }
        _clearListing($, tokenId);
        creditSale($, tokenId, msg.sender, listing.seller, listing.price, false);
        $.maskuza.safeTransferFrom(listing.seller, msg.sender, tokenId);
    }

    function openOffer(
        MarketTypes.MarketplaceStorage storage $,
        uint256 tokenId,
        uint128 price,
        uint64 expiry,
        bool collectionOffer,
        bool usesWeth
    ) public {
        _checkPrice(price);
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_OFFER_DURATION) revert OfferExpired();
        if (collectionOffer) tokenId = 0;
        else if ($.tokenAuction[tokenId] != 0) revert TokenAlreadyEscrowed();

        uint256 offerId = ++$.nextOfferId;
        $.offers[offerId] = MarketTypes.Offer(msg.sender, tokenId, price, expiry, collectionOffer, usesWeth, true);
        if (collectionOffer) $.collectionOfferIds.push(offerId);
        else $.tokenOfferIds[tokenId].push(offerId);

        if (usesWeth) {
            if (msg.value != 0) revert WrongPayment();
            address token = $.weth;
            if (token == address(0)) revert WethNotSet();
            $.wethOfferEscrow += price;
            if (!IWETH(token).transferFrom(msg.sender, address(this), price)) revert WethTransferFailed();
        } else {
            if (msg.value != price) revert WrongPayment();
            $.ethOfferEscrow += price;
        }
        emit OfferMade(offerId, tokenId, msg.sender, price, expiry, collectionOffer, usesWeth);
    }

    function closeOffer(MarketTypes.MarketplaceStorage storage $, uint256 offerId) public {
        MarketTypes.Offer storage item = $.offers[offerId];
        if (!item.active) revert OfferInactive();
        if (msg.sender != item.buyer && block.timestamp < item.expiry) revert NotBuyer();
        uint256 price = item.price;
        address buyer = item.buyer;
        uint256 tokenId = item.tokenId;
        bool usesWeth = item.weth;
        item.active = false;
        if (usesWeth) {
            $.wethOfferEscrow -= price;
            if (!IWETH($.weth).transfer(buyer, price)) revert WethTransferFailed();
        } else {
            $.ethOfferEscrow -= price;
            $.pendingWithdrawals[buyer] += price;
            $.pendingTotal += price;
        }
        emit OfferCancelled(offerId, tokenId, buyer);
    }

    function fillOffer(MarketTypes.MarketplaceStorage storage $, uint256 offerId, uint256 tokenId) public {
        MarketTypes.Offer storage item = $.offers[offerId];
        if (!item.active) revert OfferInactive();
        if (block.timestamp >= item.expiry) revert OfferExpired();
        if (!item.collectionOffer && item.tokenId != tokenId) revert WrongToken();
        if (msg.sender == item.buyer) revert BuyerIsSeller();
        if ($.maskuza.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (!_approved($, msg.sender, tokenId)) revert NotApproved();
        if ($.tokenAuction[tokenId] != 0) revert TokenAlreadyEscrowed();

        uint256 price = item.price;
        bool usesWeth = item.weth;
        address buyer = item.buyer;
        item.active = false;
        if (usesWeth) $.wethOfferEscrow -= price;
        else $.ethOfferEscrow -= price;
        if ($.listings[tokenId].price != 0) {
            address previous = $.listings[tokenId].seller;
            _clearListing($, tokenId);
            if (previous == msg.sender) emit ListingCancelled(tokenId, previous);
            else emit ListingInvalidated(tokenId, previous);
        }
        emit OfferAccepted(offerId, tokenId, buyer, msg.sender, price);
        creditSale($, tokenId, buyer, msg.sender, price, false);
        if (usesWeth) IWETH($.weth).withdraw(price);
        $.maskuza.safeTransferFrom(msg.sender, buyer, tokenId);
    }

    function creditSale(
        MarketTypes.MarketplaceStorage storage $,
        uint256 tokenId,
        address buyer,
        address seller,
        uint256 price,
        bool fromDeposit
    ) public {
        (address royaltyTo, uint256 royaltyAmt) = $.royaltySource.royaltyInfo(tokenId, price);
        uint256 minimum = (price * ROYALTY_BPS) / BPS;
        if (minimum == 0 || royaltyTo == address(0) || royaltyAmt < minimum) revert RoyaltyNotPaid();
        (uint256 sellerAmount, uint256 feeAmount, uint256 royalty) = SaleSplit.quote(price, $.feeBps, royaltyAmt);
        if (sellerAmount != 0) $.pendingWithdrawals[seller] += sellerAmount;
        if (feeAmount != 0) $.pendingWithdrawals[$.feeRecipient] += feeAmount;
        if (royalty != 0) $.pendingWithdrawals[royaltyTo] += royalty;
        $.pendingTotal += price;
        if (fromDeposit) $.auctionProceedsCredited += price;
        MarketTypes.TokenSaleStats storage stats = $.saleStats[tokenId];
        stats.lastPrice = uint128(price);
        stats.saleCount += 1;
        emit Sale(tokenId, buyer, seller, price, sellerAmount, feeAmount, royalty);
    }

    function page(uint256[] storage ids, uint256 offset, uint256 limit) public view returns (uint256[] memory out) {
        if (limit > MAX_PAGE) limit = MAX_PAGE;
        if (offset >= ids.length || limit == 0) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > ids.length) end = ids.length;
        out = new uint256[](end - offset);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = ids[offset + i];
        }
    }

    function _clearListing(MarketTypes.MarketplaceStorage storage $, uint256 tokenId) internal {
        uint256 pos = $.listingPos[tokenId];
        if (pos != 0) {
            uint256 last = $.activeListingIds.length - 1;
            uint256 idx = pos - 1;
            if (idx != last) {
                uint256 moved = $.activeListingIds[last];
                $.activeListingIds[idx] = moved;
                $.listingPos[moved] = idx + 1;
            }
            $.activeListingIds.pop();
            delete $.listingPos[tokenId];
        }
        delete $.listings[tokenId];
    }

    function _fillable(MarketTypes.MarketplaceStorage storage $, uint256 tokenId, address seller, uint64 expiry)
        internal
        view
        returns (bool)
    {
        if (expiry != 0 && block.timestamp >= expiry) return false;
        if ($.maskuza.ownerOf(tokenId) != seller) return false;
        return _approved($, seller, tokenId);
    }

    function _approved(MarketTypes.MarketplaceStorage storage $, address owner, uint256 tokenId)
        internal
        view
        returns (bool)
    {
        IERC721 token = $.maskuza;
        return token.getApproved(tokenId) == address(this) || token.isApprovedForAll(owner, address(this));
    }

    function _checkPrice(uint256 price) internal pure {
        if (price == 0) revert ZeroPrice();
        if (price < MIN_PRICE) revert PriceTooLow();
        if (price > type(uint128).max) revert PriceTooHigh();
    }

    function _checkExpiry(uint64 expiry) internal view {
        if (expiry != 0 && expiry <= block.timestamp) revert ListingExpired();
    }
}
