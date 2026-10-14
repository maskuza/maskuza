// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SaleSplit
/// @notice Pure fee and royalty split used by the MASKUZA marketplace.
library SaleSplit {
    error FeesExceedPrice();

    uint256 internal constant BPS = 10_000;

    /// @notice Split `price` into seller proceeds, marketplace fee, and royalty.
    /// @param royaltyAmount Royalty already quoted by EIP-2981. Pass zero when there is no receiver.
    function quote(uint256 price, uint256 feeBps, uint256 royaltyAmount)
        internal
        pure
        returns (uint256 sellerAmount, uint256 feeAmount, uint256 royalty)
    {
        feeAmount = (price * feeBps) / BPS;
        royalty = royaltyAmount;
        if (feeAmount + royalty > price) revert FeesExceedPrice();
        sellerAmount = price - feeAmount - royalty;
    }
}
