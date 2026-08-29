// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./HindsightFixture.sol";

contract ReputationTest is HindsightFixture {
    address constant HONEST = address(0xA11CE);
    address constant SHARK = address(0x5AA4);

    function test_unknown_address_pays_full_base_bond() public view {
        // m defaults to 1.0 — discounts are earned, never granted (Sybil defense).
        uint256 b = hook.previewBond(poolId, address(0xDEAD), 1e18);
        assertEq(b, 1e18 * 25 / 10_000);
    }

    function test_benign_history_earns_bond_discount() public {
        uint256 quoteBefore = hook.previewBond(poolId, HONEST, 1e18);

        // Three benign settled swaps.
        for (uint256 i; i < 3; i++) {
            uint256 id = hook.nextSwapId();
            swapAs(HONEST, true, -1e15);
            advanceTo(pastWindow(id));
            hook.settle(id);
        }

        uint256 quoteAfter = hook.previewBond(poolId, HONEST, 1e18);
        assertLt(quoteAfter, quoteBefore, "benign history reduces the bond");
        assertEq(hook.benignSettles(HONEST), 3);
        // 3 settles x 3% discount
        assertApproxEqRel(quoteAfter, quoteBefore * 91 / 100, 0.001e18);
    }

    function test_toxic_settle_resets_discount_and_raises_multiplier() public {
        // Earn a discount first.
        for (uint256 i; i < 3; i++) {
            uint256 id = hook.nextSwapId();
            swapAs(SHARK, true, -1e15);
            advanceTo(pastWindow(id));
            hook.settle(id);
        }
        assertEq(hook.benignSettles(SHARK), 3);

        // Then get caught being toxic.
        uint256 toxicId = hook.nextSwapId();
        swapAs(SHARK, true, -1e18);
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(toxicId));
        hook.settle(toxicId);

        assertEq(hook.benignSettles(SHARK), 0, "discount history wiped");
        assertGt(hook.toxicityScore(SHARK), 0, "EMA raised");
        uint256 quote = hook.previewBond(poolId, SHARK, 1e18);
        assertGt(quote, 1e18 * 25 / 10_000, "penalty multiplier above base");
    }

    function test_discount_floor_at_10pct() public {
        // 50 benign settles would imply a 150% discount — must floor at 0.1x.
        for (uint256 i; i < 40; i++) {
            uint256 id = hook.nextSwapId();
            swapAs(HONEST, true, -1e14);
            advanceTo(pastWindow(id));
            hook.settle(id);
        }
        uint256 quote = hook.previewBond(poolId, HONEST, 1e18);
        assertEq(quote, uint256(1e18 * 25 / 10_000) / 10, "floored at m_min = 0.1");
    }
}
