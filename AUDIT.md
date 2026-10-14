# MASKUZA marketplace self-audit

This is a self-audit of `MaskuzaMarketplace`, `MarketOrders`, and `SaleSplit` as of this revision. It is not a substitute for an independent audit. Do not treat a passing test suite, or the notes below, as a sign-off from an unaffiliated reviewer.

The collection (`Maskuza`, ERC-721C, the mint schedule) is in scope for sales where they depend on `royaltyInfo`, ownership, and approval. The encrypted slot assignment is in [Hidden reveal](#hidden-reveal). The threat model is [SECURITY.md](SECURITY.md).

## Method

- Line review of listings, offers, auctions, withdrawals, royalty and fee splits, storage layout, and access control.
- Foundry unit tests, fuzz tests (`SaleSplit` quote conservation, listing purchase, ETH offer escrow), and invariant tests (`address(market).balance == accountedEth()` and `WETH.balanceOf(market) == wethEscrow()`).
- Slither 0.11.6, excluding dependencies, tests, and scripts, at informational and low severity suppressed. The command and the remaining results are in [Slither](#slither).
- Aderyn was not installed in this environment (`aderyn` was not on `PATH`). It was not run. An independent review should run it, or an equivalent Rust-based analyzer, against this tree.

No Critical or High issue was left open. Findings that are fixed are fixed in this revision. Findings that are acknowledged are accepted properties of the design, or limits that a code change cannot honestly remove.

## What the marketplace does

Listings are non-custodial. The token stays with the seller until `buy`, `batchBuy`, or `acceptOffer`. Auctions pull the token with `transferFrom` and hold it until settlement, cancellation, or unwind. Offers escrow ETH (`msg.value == price`) or WETH (`transferFrom` of the configured WETH). Every completed sale goes through `creditSale`, which reverts unless `royaltyInfo` returns a non-zero receiver and at least 5% of the price, and that 5% is at least 1 wei. The marketplace fee is at most 10% (default 2.5%). `SaleSplit` reverts if fee plus royalty exceeds the price.

`accountedEth()` is `pendingTotal + depositTotal + ethOfferEscrow - auctionProceedsCredited`. The last term exists because an auction credits the sale while the winner's deposit still holds the same ETH. `refundBid` then removes the clearing price from `auctionProceedsCredited` and credits only `deposit - price` to the winner.

There are no off-chain orders and no EIP-712 signatures. A signature cannot be replayed because none is accepted. Auction inputs still go through `FHE.fromExternal`, which binds the proof to `msg.sender`.

## Findings

### M-1. Stale listing after a transfer or a revoked approval

Severity: Medium. Status: fixed.

A listing used to be a record that `buy` might trust after the seller had moved the token or cleared approval. `quote` and `buyOne` now revert `ListingStale` unless `ownerOf` is still the seller and this marketplace is still approved (`getApproved` or `isApprovedForAll`). An expired listing reverts `ListingExpired`. `acceptOffer` does the same ownership and approval checks, and it also reverts if the token is in an auction.

`invalidateListing` is permissionless once the listing is expired, the seller is no longer the owner, or approval is gone. It does not delete a listing that can still be filled.

The active-listing page is the set of records, not a filtered view of fillable ones. Pruning inside the view would walk an unbounded set. Buyers and indexers must treat a row as fillable only after `quote` would succeed, or after a successful `buy`. A stale row blocks `createAuction` until `invalidateListing`. The new owner can call that themselves. It is an extra transaction, not a stuck token.

Auctions stay custodial so a transfer cannot pull the token out from under a sealed bid.

### M-2. Royalty rounded away at dust prices

Severity: Medium. Status: fixed.

`price * 500 / 10000` is 0 for every price below 20 wei. A sale at that price would have satisfied a careless `>= 5%` check while paying no royalty. `MIN_PRICE` is 20 wei. `creditSale` reverts `RoyaltyNotPaid` when the minimum is 0, the receiver is the zero address, or `royaltyInfo` returns less than the 5% minimum. Auction eligibility includes `FHE.ge(amount, MIN_PRICE)`, so a bid under the floor cannot become the high bid and then trap `finalizeAuction` on `RoyaltyNotPaid`. After the grace period the auction can still be unwound if settlement reverts for any other reason.

Rounding above the floor is the usual basis-point truncation. The remainder stays in the seller's proceeds. That is not a way to pay less than the integer 5%.

### M-3. Auction proceeds counted twice

Severity: Medium. Status: fixed.

Settlement credits `price` into `pendingTotal` before the winner's deposit is reduced. Without `auctionProceedsCredited`, `accountedEth()` would be short or long by `price` depending on which counter was updated. The subtraction is reversed in `refundBid` for the winner only. Unit tests assert `accountedEth()` after a listing purchase and after sealed-bid refunds. The invariant handler drives listings, ETH offers, WETH offers, cancels, accepts, and withdrawals. It does not submit fhEVM bids. Those paths are covered by `MaskuzaMarketplace.t.sol`, not by the invariant campaign, because a random bid needs a valid input proof.

### M-4. Reentrancy on ETH, WETH, and the NFT

Severity: Medium. Status: fixed for value-moving calls. Residual detector noise is [S-1](#s-1-reentrancy-no-eth-on-the-auction-path).

`nonReentrant` covers list, update, cancel, invalidate, buy, batch buy, both offer entries, cancel offer, accept offer, create auction, cancel auction, bid, request settlement, finalize, unwind, refund, and withdraw. Credits, escrow counters, and listing or offer deactivation are written before any external call. `withdraw` zeros the credit, then sends ETH. `acceptOffer` reduces escrow and credits the sale, then unwraps WETH, then `safeTransferFrom`. `receive` accepts ETH only from the configured WETH, so a plain transfer cannot mint a credit. `onERC721Received` reverts, so a `safeTransfer` cannot push a token into the marketplace. Auction escrow uses `transferFrom`, which does not call the receiver.

A callback from the NFT or from WETH during the outer call hits the reentrancy guard. The guard is on the marketplace. `MarketOrders` is a public library and runs by delegatecall, so it sees the guard in the proxy's storage.

### L-1. `batchBuy` accumulator

Severity: Informational. Status: fixed.

`uint256 total` in `batchBuy` was left to Solidity's zero default. The sum was already correct. It is now `uint256 total = 0` so a reader, and Slither's uninitialized-local detector, do not have to rely on that default.

### L-2. No order-signature replay

Severity: Informational. Status: not applicable.

The marketplace does not accept a signed order. There is no order hash, nonce, or signature to replay. `FHE.fromExternal` still rejects an auction input proof that was built for a different sender. Copying someone else's ciphertext fails verification. That check is the existing auction test, not a new signature scheme.

### L-3. Front-running and griefing

Severity: Informational. Status: acknowledged.

- A seller can `updateListing`, `cancelListing`, or transfer the token before a buy is mined. `buy` pays the price at execution, exactly. A changed price reverts `WrongPayment` or `ListingStale`. The buyer is not charged a higher price. There is no slippage argument, so a price cut also reverts until the buyer resubmits.
- A buyer can `cancelOffer` before `acceptOffer`. The accept reverts `OfferInactive`. The seller does not receive the tokens.
- Two sellers can race one collection offer. The first successful `acceptOffer` clears `active`. The second reverts. The buyer asked for any token in the collection. The token they receive is whichever fill lands first.
- Offer id arrays only grow. Inactive ids stay so a fill does not walk the array. `tokenOffers` and `collectionOffers` return a page of at most 50 ids, including inactive ones. `offer(id).active` is the filter. State-changing functions do not loop those arrays.
- `MAX_BATCH` is 20. A batch reverts as a whole, including when the same token id appears twice.

### L-4. Royalty bypass outside this contract

Severity: Medium for the collection policy. Status: acknowledged. Inside this marketplace the 5% check is enforced.

`creditSale` is the only sale path for listings, offers, and auctions. It will not pay a royalty under 5% or a royalty to the zero address. That does not bind the rest of Ethereum.

- The transfer validator does not read `msg.value`. A whitelisted operator other than this marketplace can move a token without paying.
- An EOA can transfer to another EOA. `caller == from` is allowed under the ruleset this collection uses.
- EIP-2981 on any other market is informational. Those markets can ignore it.
- `royaltyInfo` on the current collection is fixed at 500 bps. An owner upgrade of the collection could report a higher amount. `SaleSplit` still reverts when fee plus royalty exceeds the price, so the seller cannot be debited more than the sale. A compromised collection owner can point the receiver at themselves. That is the admin key, also described in SECURITY.md.
- Fee and royalty are both integer division. The fuzz tests check `seller + fee + royalty == price` for the pure split, and the listing fuzz checks that a 2.5% fee and a 5% royalty are the credits actually stored.

### L-5. Forced ETH, donated WETH, and a hostile WETH

Severity: Low. Status: acknowledged.

A `selfdestruct` beneficiary, or a coinbase payment, can raise the contract's ETH balance above `accountedEth()`. There is no sweep. `withdraw` pays `pendingWithdrawals` only, so the excess is stuck. It is not credited to an attacker. The invariant `balance == accountedEth()` holds for ETH that entered through `buy`, `bid`, `makeOffer`, and WETH `withdraw`. It is not a claim about forced ETH.

A direct WETH transfer raises `WETH.balanceOf(this)` above `wethEscrow()`. Offer pulls use the counter, not the balance, so the donation is not spendable by a later offer. It is stuck the same way.

`setWeth` is `onlyOwner` and reverts while `wethOfferEscrow != 0`. The owner is trusted to set canonical WETH. A fee-on-transfer token, or a `withdraw` that does not deliver `price` ETH, would credit sellers against other users' ETH. This contract does not try to defend against a WETH the owner chose.

### L-6. Upgrade and storage

Severity: Informational. Status: acknowledged, with a layout rule.

Marketplace state is the ERC-7201 namespace `maskuza.marketplace` at `0xc87f49dd6db1bccfab4d055db07f78b24a6b9866f4e5af289afc7dac8b273d00`. New fields were appended. `Listing` gained `expiry` as a third slot. In a mapping, appending a field does not move `seller` or `price` for an existing key. `expiry == 0` means no expiry, which is the safe default for an older row. Nothing in this repository has been deployed to a public network, so there is no live storage to migrate. A later upgrade must keep that order and must only append.

`MarketOrders` is a public library. Foundry links its address into the marketplace implementation. The proxy delegatecalls the implementation, which delegatecalls the library, and both see proxy storage. A direct call to the library uses the library's own empty storage and is not payable, so it cannot take the proxy's ETH. An upgrade is a new implementation, which links whatever library that build deployed. Review both bytecodes. `_authorizeUpgrade` is `onlyOwner`. `Ownable2Step` means a pending owner who has not accepted cannot upgrade. The implementation constructor disables initializers.

### L-7. Access control

Severity: Informational. Status: by design.

| Action | Who |
| --- | --- |
| `setFee`, `setWeth`, `pause`, `unpause`, upgrade | Owner |
| `list`, `updateListing`, `cancelListing`, `createAuction`, `cancelAuction` | The token owner, or the seller of record for a cancel |
| `cancelOffer` | The buyer, or anyone after expiry |
| `invalidateListing` | Anyone, only when the listing cannot be filled |
| `buy`, `acceptOffer`, `bid`, settlement, `refundBid`, `withdraw` | The participant the function names. Settlement and unwind are permissionless on purpose, after the time check |

Pause blocks new listings, buys, offers, accepts, bids, and auctions. It does not block cancel, invalidate, refund, withdraw, or settlement. Credits already written are not moved by a later `setFee`.

### L-8. Indexed event topics

Severity: Informational. Status: acknowledged.

The EVM allows three indexed topics. Identity fields are indexed: `tokenId`, and the seller, buyer, bidder, or winner as the event defines them. `price` is in the data payload, not a fourth topic. An indexer that filters only on topics will not filter by price. It can still decode the price from the data. The same event signatures are declared on `MaskuzaMarketplace` and on `MarketOrders`. The library emits during delegatecall, so the log address is the proxy. Filter on the proxy.

Events for the activity set: `Listed`, `ListingUpdated`, `ListingCancelled`, `ListingInvalidated`, `Sale`, `OfferMade`, `OfferCancelled`, `OfferAccepted`, `AuctionCreated`, `BidPlaced`, `SettlementRequested`, `AuctionSettled`, `AuctionCancelled`, `AuctionUnwound`, `BidRefunded`, `Withdrawal`, `FeeUpdated`, `WethSet`.

`saleStats` stores `lastPrice` (`uint128`) and `saleCount` (`uint64`) in one slot. A price above `uint128` max cannot be listed or offered (`PriceTooHigh`). Auction clearing prices are `uint64`.

### S-1. Reentrancy-no-eth on the auction path

Severity: Informational. Status: acknowledged.

Slither reports `reentrancy-no-eth` on `bid`, `_considerHighest`, and `finalizeAuction`. The callees are fhEVM host functions (`fheRand`, `fheIfThenElse`, `allow`, `checkSignatures`) and `transferFrom` after settlement state is stored. The coprocessor is the protocol the auction is built on. `nonReentrant` covers `bid` and `finalizeAuction`. `checkSignatures` has to run before the contract writes the clear winner. Writing that state first would trust the caller. A dishonest coprocessor can still name a chosen winner. That trust assumption is in SECURITY.md and is not something this audit removes.

### S-2. `msg.value` inside `MarketOrders.openOffer`

Severity: Informational. Status: false positive.

Slither reports `msg-value-in-nonpayable` because `openOffer` is a public library function and reads `msg.value`. The marketplace reaches it only by delegatecall from payable `makeOffer`. Delegatecall keeps the outer `msg.value`. A direct call to the library is not payable, so it cannot be used to park ETH in the library. Making `openOffer` payable would let a stray call attach value to the library address. It stays non-payable.

## Slither

```bash
slither . --exclude-dependencies --filter-paths "test/|script/" --fail-none --exclude-informational --exclude-low
```

The run for this revision reported 6 results and nothing else at medium or higher: 5 `reentrancy-no-eth` (S-1) and 1 `msg-value-in-nonpayable` (S-2). `batchBuy`'s accumulator is initialized, so the uninitialized-local detector did not fire. No medium-or-higher detector fired on `Maskuza`.

## Invariants that were checked in tests

- ETH balance equals `accountedEth()` across listing, offer, cancel, accept, and withdraw sequences, and after the auction tests' purchases and refunds.
- WETH balance equals `wethEscrow()` across WETH offers, cancels, and accepts.
- For a split that does not revert, seller proceeds plus fee plus royalty equals the price.
- A listing sale at the default 250 bps fee credits 5% to the royalty receiver, 2.5% to the fee recipient, and the rest to the seller, and the contract balance equals that price.

## Hidden reveal

This revision also covers the collection's encrypted slot assignment. It is the same kind of note as the rest of this file: written with the code, not an independent audit.

### Design

The art pool is 666 records indexed by slot `0..665`, uploaded with `setRevealedArt` in batches of at most 8 and stored through SSTORE2. The pool is public. It does not name a token. `lockRevealedArt` freezes it.

At mint, index `tokenId - 1` is mapped to a slot by a 3-half-round unbalanced Feistel cipher on the rectangle `18 × 37 = 666`. Split `x` into `A = x / 37` (0..17) and `B = x % 37` (0..36). Each half-round is

```
side = (side + ((other * other xor key) mod modulus)) mod modulus
```

with moduli 18, then 37, then 18, and three independent `FHE.randEuint16()` round keys. The slot is `A * 37 + B`, which lands in `0..665`. The keys are generated on the first mint, stored on the collection, and `FHE.allowThis` only. They are not given to the minter and they are never made publicly decryptable.

The holder receives `FHE.allowThis` plus `FHE.allow(slot, owner)` on that `euint16`. `encryptedSlot(tokenId)` returns the handle. User decryption is off-chain. `tokenURI` stays the sealed chest, with name `MASKUZA #<tokenId>`, description `666 MASKUZA. Unrevealed.`, and no attributes field, until finalize.

`reveal` is holder-only. It calls `FHE.makePubliclyDecryptable` and emits `RevealRequested`. `finalizeReveal` calls `FHE.checkSignatures` on `abi.encode` of the `uint16` slot, the same static-type encoding as marketplace settlement. Then it stores the plain slot, marks that slot used, and sets `isRevealed`. A slot outside `0..665` or already used reverts `SlotTaken`. The revealed name is `MASKUZA #<tokenId>`. An empty pool description becomes `666 MASKUZA.`.

### Why this is collision-free, and why it is not a shared offset

A Feistel step is a bijection for any round function: the other half is unchanged, and the updated half is an addition modulo its own modulus, which is invertible by subtraction. Three steps, then the recombination `A * 37 + B`, are a bijection of `{0..665}` onto itself. Two token indexes cannot share a slot, for any keys. The 666-mint test decrypts every handle in the mock plaintext table and checks that the 666 slots are unique and inside range.

This is not `slot = (index + secret) mod 666` and not `slot = (a * index + b) mod 666`. Those maps let one revealed `(index, slot)` pair recover the secret, and then every other token's slot. Here the public index and one revealed slot determine the final `(A, B)` digits, and those digits are one modular image of `xor` then `rem` under a 16-bit key. Many keys agree with one such equation. The keys are not published.

It is not an information-theoretic uniform draw from all 666! permutations. The image is the Feistel family, which is much smaller than `S_666`. Enough revealed tokens could, in principle, support an algebraic search for the three round keys. That residual is accepted because a full encrypted Fisher-Yates does not fit, and because one reveal still does not hand the remaining assignment to an observer the way a linear offset does. The coprocessor and the KMS are trusted for the usual fhEVM reasons: they can always ignore the circuit.

### Why not Fisher-Yates

An online shuffle over 666 encrypted slots is one `eq` plus one `select` per remaining index. On `euint16` those are 55,000 HCU each, about 110,000 per index, about 73 million for one draw. The host rejects a transaction at 20,000,000 HCU. A linear chain of selects also exceeds the 5,000,000 sequential-depth cap after roughly 90 steps. `randEuint16(bound)` reverts unless `bound` is a power of two, and 666 is not. Rejection sampling cannot branch on an encrypted failure bit inside one call. Chunking the shuffle across transactions still accumulates depth on the accumulator handle.

### Gas and HCU per mint

Foundry `gasleft()` around `ownerMint` of one token, on the forge-fhevm mock executor:

| Mint | EVM gas |
| --- | --- |
| First, which also samples the three round keys | 672,005 |
| Next | 436,221 |
| A later one in the same suite | 429,728 |

That gas is the mock host. It is not a mainnet coprocessor quote. The limit that matters on Sepolia is HCU, from the host schedule for `euint16`:

- enc-enc `mul` 222,000, enc-enc `xor` 31,000, scalar `rem` 580,000, enc-enc `add` 93,000, scalar `mul` 193,000, trivial encrypt 32, `randEuint16` 23,000.
- One half-round is `mul + xor + rem + add + rem` = 1,506,000. Three half-rounds, two trivial encrypts, one scalar `mul`, and one `add` are **4,804,064 HCU**.
- The first mint adds three `randEuint16` calls: **4,873,064 HCU**.

The transaction cap is 20,000,000, so three draws fit (the first plus two more is about 14.5 million) and a fourth is close enough to the cap that `MAX_DRAW_PER_TX` is 3. `ownerMint` of 4 reverts `DrawBatchTooLarge` before any draw. Paid mint is already quantity 1. `test_threeDrawsFitInOneTransaction` mints 3 in one call with the real transaction cap left on.

Sequential depth of the slot handle, using `result = opHCU + max(input depths)`, is **4,804,032**, under the production cap of 5,000,000. Tests deploy `HCULimitNoDepthCap`, which still charges the transaction total and does not revert on depth. The depth figure is this schedule, not a revert the suite can see.

### ACL on transfer

`_update` grants the new owner with `FHE.allow` on the same handle. The handle does not change. `FHE.allow` is persistent. A previous owner keeps their old grant and can still user-decrypt.

`FHE.add(slot, 0)` would mint a fresh handle that only the new owner is allowed on. Each such add costs 93,000 HCU and adds 93,000 to the sequential depth. Starting from 4,804,032, two refreshes land at 4,990,032 and the third lands at 5,083,032, which is past 5,000,000. A transfer that re-encrypts would eventually revert on the live host, including a marketplace sale. The handle is therefore not rotated. Previous-owner decryption is an accepted limitation.

### What the tests mock

`forge test` deploys the forge-fhevm host (ACL, executor, input verifier, KMS verifier) at the canonical addresses on chain id 31337 and signs with the mock KMS key.

| Call | What it actually does |
| --- | --- |
| `decrypt(handle)` | Reads the mock plaintext table. Does not check ACL. Used for the 666-slot uniqueness check. |
| `userDecrypt` | Requires persistent ACL for the user and the contract, and a valid EIP-712 user signature. Used for the holder / non-holder / previous-owner checks. |
| `buildDecryptionProof` | Signs the cleartext bytes it is given. It does not check that the handle is publicly decryptable, and it does not check that those bytes are the plaintext of the handle. A bad-proof test signs `abi.encode(uint256[])`. The contract checks `abi.encode(uint16)`. |
| `checkSignatures` | Checks that the KMS signature matches the handles and the abi-encoded cleartext. It does not recompute the plaintext. |
| HCU transaction cap | Enforced, at 20,000,000. |
| HCU depth cap | Not enforced. `HCULimitNoDepthCap` stores the deeper handle instead of reverting. |

Production security is the Zama ACL, the KMS threshold, and the coprocessor. This section is not a substitute for an independent audit.

## Independent review

A self-audit is not a substitute for an independent audit. This note was written by the same author as the code. It should be read as a map of what was considered and what was deliberately left in place. Commission a separate review before relying on the marketplace with real funds, and include the fhEVM host, the Limit Break validator, and the deployment bytecode in that scope.
