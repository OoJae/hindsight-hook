// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./HindsightFixture.sol";

/// A beneficiary that rejects its refund must not be able to stall the automation lanes.
contract RejectingBeneficiary {
    // no receive/fallback that accepts tokens is irrelevant for ERC20, so burn all gas instead
    fallback() external payable {
        while (true) {}
    }
}

contract BatchIsolationTest is HindsightFixture {
    address constant GOOD = address(0xBEEF);

    function test_poisoned_record_does_not_revert_the_batch() public {
        // a normal swap plus one attributed to a hostile contract
        uint256 goodId = hook.nextSwapId();
        swapAs(GOOD, true, -1e17);

        RejectingBeneficiary hostile = new RejectingBeneficiary();
        fundTrader(address(0xA77));
        uint256 badId = hook.nextSwapId();
        vm.prank(address(0xA77), address(0xA77));
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e17,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(hostile))
        );

        advanceTo(pastWindow(badId));
        uint256[] memory ids = new uint256[](2);
        ids[0] = badId; // poisoned first: must not block the rest
        ids[1] = goodId;

        uint256 n = hook.settleBatch(ids); // must not revert
        assertEq(hook.getSwap(goodId).status, 1, "healthy record still settles");
        assertGe(n, 1, "batch made progress despite a poisoned record");
    }
}
