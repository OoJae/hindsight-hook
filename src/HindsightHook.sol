// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IFlashblockNumber} from "./interfaces/IFlashblockNumber.sol";
import {MarkoutLib} from "./libraries/MarkoutLib.sol";
import {BondMathLib} from "./libraries/BondMathLib.sol";
import {ToxicityLib} from "./libraries/ToxicityLib.sol";
import {ObservationLib} from "./libraries/ObservationLib.sol";

/// @title HindsightHook — ex-post markout-settled fees for Uniswap v4
///
/// @notice Every swap escrows a small refundable bond (ERC-6909 claims, charged via
/// afterSwapReturnDelta). After the trade's settlement window closes — measured in
/// FLASHBLOCKS (~200ms) on Unichain via Uniswap's official FlashblockNumber contract —
/// anyone may call settle():
///   • benign markout  (price did not keep moving the trader's way)  → full bond refund
///   • toxic markout   (the trade predicted the move = informed flow) → bond forfeited,
///     dripped to in-range LPs via PoolManager.donate()
///
/// The mechanism prices flow ex-post from realized outcomes, so it cannot be gamed by
/// revert-spam (a reverted tx never lands, never posts a bond, never enters the
/// measurement) — unlike ex-ante priority-fee MEV taxes.
///
/// Trader protections (see mechanism-spec.md):
///   • threshold θ is scaled by the window's realized volatility — trending markets do
///     not confiscate benign momentum flow ("we tax information, not volatility")
///   • missing window data within the grace period ⇒ REFUND (data withholding can never
///     punish a trader); beyond grace, unsettled bonds auto-forfeit to LPs (waiting out
///     the observation ring buffer is not an escape hatch for toxic flow)
///   • settlement window closes strictly in the past — settle() is a pure read + payout
contract HindsightHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using ObservationLib for ObservationLib.Buffer;

    // ─────────────────────────────────── errors ────────────────────────────────────
    error NotMatured();
    error AlreadySettled();
    error UnknownSwap();
    error CallerNotManager();
    error NotOwner();

    // ─────────────────────────────────── events ────────────────────────────────────
    event SwapRecorded(
        uint256 indexed swapId,
        PoolId indexed poolId,
        address indexed trader,
        bool zeroForOne,
        uint128 notional,
        uint128 bond,
        uint48 execStamp,
        int24 execTick
    );
    event Settled(
        uint256 indexed swapId,
        address indexed trader,
        bool toxic,
        int256 markoutTicks,
        int256 thresholdTicks,
        uint128 refund,
        uint128 forfeit,
        uint128 tip
    );
    event DonationFlushed(PoolId indexed poolId, uint128 amount0, uint128 amount1);

    // ─────────────────────────────────── params ────────────────────────────────────
    struct HindsightParams {
        uint24 bondBps;                // b0: base bond as bps of the unspecified amount (e.g. 25)
        uint16 maturityStamps;         // N: flashblocks from execution until the window opens
        uint16 twapWindowStamps;       // W: width of the settlement TWAP window
        uint16 graceStamps;            // beyond exec + N + W + grace, unsettled ⇒ auto-forfeit
        int24 thetaMinTicks;           // θ_min floor for the toxicity threshold
        uint16 thetaVolMultX10;        // k×10: θ = θ_min + k·realizedVol (28 ⇒ k = 2.8)
        int24 rampTicks;               // forfeit ramp width beyond θ (full forfeit at θ + ramp)
        int24 maxJumpTicks;            // per-observation TWAP contribution clamp (manipulation cap)
        uint16 keeperTipBps;           // tip to settle() caller, bps of the FORFEIT only
        uint16 epochStamps;            // donation drip epoch length (anti-JIT)
        uint128 sizeTierCap;           // Q*: no reputation discount above this notional (0 = off)
    }

    // ─────────────────────────────────── storage ───────────────────────────────────
    IFlashblockNumber public immutable flashblockNumber;
    uint256 public immutable fallbackStampsPerBlock; // scaling for the block.number fallback
    bool public clockFallbackForced;
    address public owner;

    mapping(PoolId => PoolKey) public poolKeys;
    mapping(PoolId => HindsightParams) public poolParams;
    mapping(PoolId => ObservationLib.Buffer) internal observations;

    struct SwapRecord {
        address trader;
        uint48 execStamp;
        bool zeroForOne;
        uint8 status; // 0 pending | 1 refunded | 2 forfeited
        PoolId poolId;
        uint128 notional;
        uint128 bond;
        bool bondIsCurrency0;
        int24 execTick;
    }

    uint256 public nextSwapId;
    mapping(uint256 => SwapRecord) public swaps;

    // Reputation (per-address EMA of toxic markout). WAD-scaled ticks.
    mapping(address => uint256) public toxicityScore;
    uint256 public constant EMA_LAMBDA_WAD = 0.9e18;
    uint256 public constant MULT_M0_WAD = 1e18;      // unknown addresses pay full bond (Sybil-proof)
    uint256 public constant MULT_SLOPE_WAD = 0.02e18; // +0.02x per WAD-tick of score
    uint256 public constant MULT_MIN_WAD = 0.1e18;
    uint256 public constant MULT_MAX_WAD = 3e18;

    // Benign-history discount: addresses earn m < 1 only through settled benign flow.
    mapping(address => uint32) public benignSettles;
    uint256 public constant DISCOUNT_PER_SETTLE_WAD = 0.03e18; // −3% bond per benign settle
    uint256 public constant DISCOUNT_FLOOR_WAD = 0.1e18;

    struct PendingDonation {
        uint128 amount0;
        uint128 amount1;
        uint48 lastFlushStamp;
    }

    mapping(PoolId => PendingDonation) public pendingDonations;

    // ────────────────────────────────── lifecycle ──────────────────────────────────
    constructor(IPoolManager _manager, IFlashblockNumber _flashblockNumber, uint256 _fallbackStampsPerBlock)
        BaseHook(_manager)
    {
        flashblockNumber = _flashblockNumber;
        fallbackStampsPerBlock = _fallbackStampsPerBlock == 0 ? 10 : _fallbackStampsPerBlock;
        owner = msg.sender;
    }

    receive() external payable {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────── flashblock clock ──────────────────────────────
    /// @notice Current flashblock stamp with graceful block.number fallback.
    /// @dev The official counter is monotonic and does NOT reset per block, and it did
    ///      not start at block 0 — so it must never be compared against a block-derived
    ///      floor (on Unichain Sepolia block.number*10 exceeds the live counter).
    ///      Rule: a present, nonzero, non-reverting counter is authoritative; the
    ///      block.number fallback applies only when the counter is absent/zero/reverting,
    ///      or when the owner has forced the fallback after a builder-infra failure.
    ///      NOTE: forcing the fallback changes the clock's origin — only do it on pools
    ///      with no pending settlements (documented emergency action).
    function currentStamp() public view returns (uint48) {
        address fb = address(flashblockNumber);
        if (!clockFallbackForced && fb.code.length > 0) {
            try IFlashblockNumber(fb).getFlashblockNumber() returns (uint256 n) {
                if (n != 0) return uint48(n);
            } catch {}
        }
        return uint48(block.number * fallbackStampsPerBlock);
    }

    /// @notice Emergency clock switch should the builder-maintained counter die.
    function forceClockFallback(bool forced) external {
        if (msg.sender != owner) revert NotOwner();
        clockFallbackForced = forced;
    }

    // ─────────────────────────────────── hooks ─────────────────────────────────────
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId id = key.toId();
        poolKeys[id] = key;
        poolParams[id] = _defaultParams();
        observations[id].write(currentStamp(), tick);
        return this.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        // Record the standing (pre-swap) price for the elapsed interval.
        observations[id].write(currentStamp(), tick);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // The bond is charged in the UNSPECIFIED currency — the side the user did not fix.
        (Currency unspecified, uint256 absUnspec, bool isCurrency0) =
            _unspecified(key, params, delta);
        if (absUnspec == 0) return (this.afterSwap.selector, 0);

        uint256 bond =
            _recordSwap(key, params.zeroForOne, _resolveTrader(sender, hookData), absUnspec, isCurrency0);
        if (bond == 0) return (this.afterSwap.selector, 0);

        // Escrow: the positive delta we return credits this hook inside the PoolManager;
        // we zero it by minting ERC-6909 claims to ourselves. No ERC-20 transfer happens.
        poolManager.mint(address(this), unspecified.toId(), bond);
        return (this.afterSwap.selector, int128(uint128(bond)));
    }

    function _unspecified(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        internal
        pure
        returns (Currency unspecified, uint256 absUnspec, bool isCurrency0)
    {
        bool exactInput = params.amountSpecified < 0;
        int128 amt;
        if (params.zeroForOne == exactInput) {
            (unspecified, amt, isCurrency0) = (key.currency1, delta.amount1(), false);
        } else {
            (unspecified, amt, isCurrency0) = (key.currency0, delta.amount0(), true);
        }
        absUnspec = uint256(uint128(amt < 0 ? -amt : amt));
    }

    function _recordSwap(
        PoolKey calldata key,
        bool zeroForOne,
        address trader,
        uint256 absUnspec,
        bool isCurrency0
    ) internal returns (uint256 bond) {
        PoolId id = key.toId();
        HindsightParams memory p = poolParams[id];
        bond = BondMathLib.bond(absUnspec, p.bondBps, _bondMultiplier(trader), p.sizeTierCap, 0);
        if (bond == 0) return 0;

        (, int24 execTick,,) = poolManager.getSlot0(id);
        uint48 stamp = currentStamp();

        uint256 swapId = nextSwapId++;
        swaps[swapId] = SwapRecord({
            trader: trader,
            execStamp: stamp,
            zeroForOne: zeroForOne,
            status: 0,
            poolId: id,
            notional: uint128(absUnspec),
            bond: uint128(bond),
            bondIsCurrency0: isCurrency0,
            execTick: execTick
        });
        emit SwapRecorded(swapId, id, trader, zeroForOne, uint128(absUnspec), uint128(bond), stamp, execTick);
    }

    // ────────────────────────────────── settlement ─────────────────────────────────
    enum CallbackOp {
        SETTLE,
        FLUSH
    }

    struct SettleData {
        uint256 swapId;
        bool toxic;
        uint256 forfeitWad; // 0..1e18 fraction of the bond forfeited
        address keeper;
        int256 markoutTicks;
        int256 thetaTicks;
    }

    /// @notice Permissionless ex-post settlement of a recorded swap.
    /// @dev The verdict is computed ONLY from observations inside the already-finalized
    ///      window [exec+N, exec+N+W]. Nothing about the current price can change it.
    function settle(uint256 swapId) external {
        SwapRecord storage r = swaps[swapId];
        if (r.trader == address(0)) revert UnknownSwap();
        if (r.status != 0) revert AlreadySettled();

        HindsightParams memory p = poolParams[r.poolId];
        uint48 nowStamp = currentStamp();
        uint48 windowStart = r.execStamp + p.maturityStamps;
        uint48 windowEnd = windowStart + p.twapWindowStamps;
        if (nowStamp < windowEnd) revert NotMatured();

        (bool toxic, uint256 fWad, int256 markoutTicks, int256 thetaTicks) =
            _verdict(r, p, nowStamp, windowStart, windowEnd);

        _updateReputation(r.trader, markoutTicks, thetaTicks, toxic);
        poolManager.unlock(
            abi.encode(CallbackOp.SETTLE, abi.encode(SettleData(swapId, toxic, fWad, msg.sender, markoutTicks, thetaTicks)))
        );
    }

    /// @notice Push the pending donation pot toward in-range LPs (epoch-gated drip).
    ///         Callable by anyone — the keeper bot calls it on a timer.
    function flushDonations(PoolId id) external {
        poolManager.unlock(abi.encode(CallbackOp.FLUSH, abi.encode(id)));
    }

    /// @dev Verdict computed only from finalized-window observations. Beyond the grace
    ///      period, unsettled bonds auto-forfeit (waiting out the ring buffer is not an
    ///      escape hatch for toxic flow — spec F1); within it, missing data ⇒ refund
    ///      (data withholding can never punish a trader — spec 3.7).
    function _verdict(
        SwapRecord storage r,
        HindsightParams memory p,
        uint48 nowStamp,
        uint48 windowStart,
        uint48 windowEnd
    ) internal view returns (bool toxic, uint256 fWad, int256 markoutTicks, int256 thetaTicks) {
        if (nowStamp > windowEnd + p.graceStamps) {
            return (true, 1e18, 0, 0);
        }
        (int24 twapTick,, bool ok) = observations[r.poolId].twap(windowStart, windowEnd, p.maxJumpTicks);
        if (!ok) return (false, 0, 0, 0);
        markoutTicks = MarkoutLib.markout(r.execTick, twapTick, r.zeroForOne);
        (uint256 vol,) = observations[r.poolId].avgAbsJump(windowStart, windowEnd);
        thetaTicks = int256(uint256(int256(p.thetaMinTicks))) + int256(vol * p.thetaVolMultX10 / 10);
        fWad = MarkoutLib.forfeitWad(markoutTicks, thetaTicks, int256(p.rampTicks));
        toxic = fWad > 0;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallerNotManager();
        (CallbackOp op, bytes memory payload) = abi.decode(data, (CallbackOp, bytes));
        if (op == CallbackOp.FLUSH) {
            PoolId id = abi.decode(payload, (PoolId));
            _maybeFlushDonations(id, poolKeys[id], poolParams[id]);
            return "";
        }
        return _settleCallback(abi.decode(payload, (SettleData)));
    }

    function _settleCallback(SettleData memory s) internal returns (bytes memory) {
        SwapRecord storage r = swaps[s.swapId];
        PoolKey memory key = poolKeys[r.poolId];
        HindsightParams memory p = poolParams[r.poolId];
        Currency c = r.bondIsCurrency0 ? key.currency0 : key.currency1;

        uint128 forfeit = uint128(uint256(r.bond) * s.forfeitWad / 1e18);
        uint128 refund = r.bond - forfeit;
        uint128 tip = uint128(uint256(forfeit) * p.keeperTipBps / 10_000);
        uint128 donation = forfeit - tip;

        r.status = s.toxic ? 2 : 1;

        // Unwrap the escrowed claims into a positive currency delta for this contract...
        poolManager.burn(address(this), c.toId(), r.bond);

        // ...then route it: refund → trader, tip → keeper, forfeit → LP donation pot.
        if (refund > 0) poolManager.take(c, r.trader, refund);
        if (tip > 0) poolManager.take(c, s.keeper, tip);
        if (donation > 0) {
            // Stash and drip (anti JIT-donation-sniping, spec E2). Taking to ourselves
            // moves the value out of flash accounting into real token custody.
            poolManager.take(c, address(this), donation);
            PendingDonation storage pd = pendingDonations[r.poolId];
            if (r.bondIsCurrency0) pd.amount0 += donation;
            else pd.amount1 += donation;
        }

        _maybeFlushDonations(r.poolId, key, p);

        emit Settled(s.swapId, r.trader, s.toxic, s.markoutTicks, s.thetaTicks, refund, forfeit, tip);
        return "";
    }

    /// @notice Drip pending forfeits to in-range LPs, at most once per epoch.
    function _maybeFlushDonations(PoolId id, PoolKey memory key, HindsightParams memory p) internal {
        PendingDonation storage pd = pendingDonations[id];
        uint48 nowStamp = currentStamp();
        if (nowStamp < pd.lastFlushStamp + p.epochStamps) return;
        if (pd.amount0 == 0 && pd.amount1 == 0) return;
        if (poolManager.getLiquidity(id) == 0) return; // Pool.donate reverts with no liquidity

        // Drip half the pot per epoch → exponential smoothing.
        uint128 d0 = pd.amount0 / 2;
        uint128 d1 = pd.amount1 / 2;
        // flush fully once the pot is dust
        if (pd.amount0 > 0 && d0 == 0) d0 = pd.amount0;
        if (pd.amount1 > 0 && d1 == 0) d1 = pd.amount1;
        if (d0 == 0 && d1 == 0) return;

        pd.amount0 -= d0;
        pd.amount1 -= d1;
        pd.lastFlushStamp = nowStamp;

        poolManager.donate(key, d0, d1, "");
        // Settle our negative deltas with the real tokens we custody.
        if (d0 > 0) _pay(key.currency0, d0);
        if (d1 > 0) _pay(key.currency1, d1);

        emit DonationFlushed(id, d0, d1);
    }

    function _pay(Currency c, uint128 amount) internal {
        if (c.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(c);
            c.transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    /// @notice Permissionless price checkpoint for quiet pools during settlement windows.
    function poke(PoolKey calldata key) external {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        observations[id].write(currentStamp(), tick);
    }

    // ────────────────────────────────── reputation ─────────────────────────────────
    function _bondMultiplier(address trader) internal view returns (uint256 m) {
        m = ToxicityLib.multiplier(
            toxicityScore[trader], MULT_M0_WAD, MULT_SLOPE_WAD, MULT_MIN_WAD, MULT_MAX_WAD
        );
        // Earned benign-history discount (only applies when no toxicity penalty is active).
        if (m == MULT_M0_WAD) {
            uint256 discount = uint256(benignSettles[trader]) * DISCOUNT_PER_SETTLE_WAD;
            uint256 floor_ = DISCOUNT_FLOOR_WAD;
            m = discount + floor_ >= MULT_M0_WAD ? floor_ : MULT_M0_WAD - discount;
        }
    }

    function _updateReputation(address trader, int256 markoutTicks, int256 thetaTicks, bool toxic)
        internal
    {
        uint256 raw = 0;
        if (toxic && markoutTicks > thetaTicks) {
            raw = uint256(markoutTicks - thetaTicks);
            benignSettles[trader] = 0; // toxicity resets the earned discount
        } else {
            unchecked {
                if (benignSettles[trader] < type(uint32).max) benignSettles[trader]++;
            }
        }
        toxicityScore[trader] = ToxicityLib.update(toxicityScore[trader], raw, EMA_LAMBDA_WAD);
    }

    function _resolveTrader(address sender, bytes calldata hookData) internal view returns (address) {
        if (hookData.length >= 32) {
            address t = abi.decode(hookData, (address));
            if (t != address(0)) return t;
        }
        // Routers implementing IMsgSender (v4-core standard) expose the true user.
        if (sender.code.length > 0) {
            try IMsgSender(sender).msgSender() returns (address u) {
                if (u != address(0)) return u;
            } catch {}
        }
        return sender;
    }

    // ─────────────────────────────────── admin/views ───────────────────────────────
    function _defaultParams() internal pure returns (HindsightParams memory) {
        return HindsightParams({
            bondBps: 25,            // 0.25% of the unspecified amount
            maturityStamps: 15,     // N ≈ 3.0s on Unichain
            twapWindowStamps: 10,   // W ≈ 2.0s
            graceStamps: 3000,      // ≈ 10 min before auto-forfeit
            thetaMinTicks: 3,       // θ floor ≈ 3 bps
            thetaVolMultX10: 28,    // k = 2.8 × realized per-observation vol
            rampTicks: 20,          // full forfeit at θ + 20 ticks
            maxJumpTicks: 60,       // TWAP contribution clamp
            keeperTipBps: 500,      // 5% of the forfeit
            epochStamps: 50,        // donation drip epoch ≈ 10s
            sizeTierCap: 0          // off by default; set per pool
        });
    }

    function setParams(PoolId id, HindsightParams calldata p) external {
        if (msg.sender != owner) revert NotOwner();
        poolParams[id] = p;
    }

    /// @notice Bond quote for a prospective swap (frontend preview).
    function previewBond(PoolId id, address trader, uint256 unspecifiedAmount)
        external
        view
        returns (uint256)
    {
        HindsightParams memory p = poolParams[id];
        return BondMathLib.bond(unspecifiedAmount, p.bondBps, _bondMultiplier(trader), p.sizeTierCap, 0);
    }

    /// @notice Preview a pending swap's provisional verdict with current data.
    function previewSettle(uint256 swapId)
        external
        view
        returns (bool matured, bool dataOk, int256 markoutTicks, int256 thetaTicks, uint256 forfeitWad_)
    {
        SwapRecord storage r = swaps[swapId];
        HindsightParams memory p = poolParams[r.poolId];
        uint48 windowStart = r.execStamp + p.maturityStamps;
        uint48 windowEnd = windowStart + p.twapWindowStamps;
        matured = currentStamp() >= windowEnd;
        (int24 twapTick,, bool ok) = observations[r.poolId].twap(windowStart, windowEnd, p.maxJumpTicks);
        dataOk = ok;
        if (ok) {
            markoutTicks = MarkoutLib.markout(r.execTick, twapTick, r.zeroForOne);
            (uint256 vol,) = observations[r.poolId].avgAbsJump(windowStart, windowEnd);
            thetaTicks = int256(uint256(int256(p.thetaMinTicks))) + int256(vol * p.thetaVolMultX10 / 10);
            forfeitWad_ = MarkoutLib.forfeitWad(markoutTicks, thetaTicks, int256(p.rampTicks));
        }
    }

    function getSwap(uint256 swapId) external view returns (SwapRecord memory) {
        return swaps[swapId];
    }

    function observationCount(PoolId id) external view returns (uint16) {
        return observations[id].count;
    }
}
