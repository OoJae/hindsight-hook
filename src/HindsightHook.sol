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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

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
    error BadParams();
    error CallerNotSelf();

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
    event TrustedRouterSet(address indexed router, bool trusted);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

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
    address public owner;
    address public pendingOwner;

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
        bool attributed; // beneficiary is authenticated: reputation may be read/written
        bool finalized;  // verdict locked in while the window's data still existed
        int24 fMarkout;  // snapshotted markout  (valid iff finalized)
        int24 fTheta;    // snapshotted theta    (valid iff finalized)
    }

    uint256 public nextSwapId;
    mapping(uint256 => SwapRecord) public swaps;

    // Reputation (per-address EMA of toxic markout). WAD-scaled ticks.
    mapping(address => uint256) public toxicityScore;

    /// @notice Routers that faithfully report their caller via IMsgSender. Only these may
    ///         attribute a swap to a third party (see `_resolveTrader`).
    mapping(address => bool) public trustedRouters;
    /// @dev Jump clamp for theta's volatility input. Deliberately tighter than the TWAP's
    ///      `maxJumpTicks`; see `_theta` for why the two defend opposite parties.
    int24 internal constant MAX_VOL_JUMP_TICKS = 10;
    uint256 internal constant EMA_LAMBDA_WAD = 0.9e18;
    uint256 public constant MULT_M0_WAD = 1e18;      // unknown addresses pay full bond (Sybil-proof)
    uint256 internal constant MULT_SLOPE_WAD = 0.02e18; // +0.02x per WAD-tick of score
    uint256 internal constant MULT_MIN_WAD = 0.1e18;
    uint256 internal constant MULT_MAX_WAD = 3e18;

    // Benign-history discount: addresses earn m < 1 only through settled benign flow.
    mapping(address => uint32) public benignSettles;
    uint256 internal constant DISCOUNT_PER_SETTLE_WAD = 0.03e18; // −3% bond per benign settle
    uint256 internal constant DISCOUNT_FLOOR_WAD = 0.1e18;

    struct PendingDonation {
        uint128 amount0;
        uint128 amount1;
        uint48 lastFlushStamp;
    }

    mapping(PoolId => PendingDonation) public pendingDonations;

    // ────────────────────────────────── lifecycle ──────────────────────────────────
    /// @param _owner explicit owner. NOT `msg.sender`: hooks are deployed through the CREATE2
    ///        factory to mine their permission-bit address, so `msg.sender` here is the
    ///        factory — which would leave `setParams`/`setTrustedRouter`/ownership
    ///        permanently unreachable.
    constructor(
        IPoolManager _manager,
        IFlashblockNumber _flashblockNumber,
        uint256 _fallbackStampsPerBlock,
        address _owner
    ) BaseHook(_manager) {
        flashblockNumber = _flashblockNumber;
        fallbackStampsPerBlock = _fallbackStampsPerBlock == 0 ? 10 : _fallbackStampsPerBlock;
        owner = _owner == address(0) ? msg.sender : _owner;
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
    ///      block.number fallback applies only when the counter is absent, zero, or
    ///      reverting — never at the owner's discretion. (An owner-forced clock switch was
    ///      removed: it would change the clock's ORIGIN mid-flight, which is exactly the
    ///      kind of retroactive power the bounded-setParams design exists to deny.)
    function currentStamp() public view returns (uint48) {
        address fb = address(flashblockNumber);
        if (fb.code.length > 0) {
            try IFlashblockNumber(fb).getFlashblockNumber() returns (uint256 n) {
                if (n != 0) return uint48(n);
            } catch {}
        }
        return uint48(block.number * fallbackStampsPerBlock);
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

        (address beneficiary, bool attributed) = _resolveTrader(sender, hookData);
        uint256 bond = _recordSwap(key, params.zeroForOne, beneficiary, attributed, absUnspec, isCurrency0);
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
        bool attributed,
        uint256 absUnspec,
        bool isCurrency0
    ) internal returns (uint256 bond) {
        PoolId id = key.toId();
        HindsightParams memory p = poolParams[id];
        // Unauthenticated attribution cannot borrow anyone's discount: it pays full freight.
        bond = BondMathLib.bond(
            absUnspec,
            p.bondBps,
            attributed ? _bondMultiplier(trader, p.sizeTierCap) : MULT_M0_WAD,
            p.sizeTierCap,
            _bondCap(id, isCurrency0, p.thetaMinTicks)
        );
        if (bond == 0) return 0;

        (, int24 execTick,,) = poolManager.getSlot0(id);
        uint48 stamp = currentStamp();
        // The trade's own post-swap price MUST enter the series, otherwise a swap in a quiet
        // window is scored against its own pre-trade price and markout = -(own impact),
        // i.e. structurally benign at any size. `beforeSwap` already wrote this stamp, so
        // this is an in-place refresh.
        observations[id].writeOrUpdate(stamp, execTick);

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
            execTick: execTick,
            attributed: attributed,
            finalized: false,
            fMarkout: 0,
            fTheta: 0
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
        bool graded; // false ⇒ ungraded forfeit (lapse or eviction): no keeper tip, see M7
    }

    /// @notice Permissionless ex-post settlement of a recorded swap.
    /// @dev The verdict is computed ONLY from observations inside the already-finalized
    ///      window [exec+N, exec+N+W]. Nothing about the current price can change it.
    function settle(uint256 swapId) external {
        SwapRecord storage r = swaps[swapId];
        if (r.trader == address(0)) revert UnknownSwap();
        if (r.status != 0) revert AlreadySettled();
        if (!_matured(r)) revert NotMatured();
        finalize(swapId);
        _doSettle(swapId, r, msg.sender);
    }

    /// @notice Non-reverting settle for batch callers (Chainlink performUpkeep, Reactive
    ///         callbacks, keeper bots). Skips instead of reverting so a racing manual
    ///         settle can never brick a batch.
    function trySettle(uint256 swapId) public returns (bool settled) {
        return _trySettle(swapId, msg.sender);
    }

    function _trySettle(uint256 swapId, address keeper) internal returns (bool) {
        SwapRecord storage r = swaps[swapId];
        if (r.trader == address(0) || r.status != 0 || !_matured(r)) return false;
        finalize(swapId);
        _doSettle(swapId, r, keeper);
        return true;
    }

    /// @notice External self-call target so `settleBatch` can isolate a failing record.
    /// @dev `keeper` is passed explicitly because under a self-call `msg.sender` is this
    ///      contract — tips would otherwise be paid to the hook instead of the caller.
    function settleOne(uint256 swapId, address keeper) external returns (bool) {
        if (msg.sender != address(this)) revert CallerNotSelf();
        return _trySettle(swapId, keeper);
    }

    /// @notice Batch settlement — settles whatever is ready and SKIPS anything that reverts.
    /// @dev Each id is settled through an external self-call so one poisoned record (e.g. a
    ///      beneficiary that rejects its refund, or burns gas in its fallback) can never
    ///      revert the whole batch and stall the automation lanes. The explicit gas stipend
    ///      stops a griefing beneficiary from OOG-ing the parent call via the 63/64 rule.
    function settleBatch(uint256[] calldata swapIds) external returns (uint256 nSettled) {
        for (uint256 i; i < swapIds.length; i++) {
            try this.settleOne{gas: 400_000}(swapIds[i], msg.sender) returns (bool ok) {
                if (ok) nSettled++;
            } catch {}
        }
    }

    /// @notice Bounded scan for matured-unsettled swaps — the shared work-discovery view
    ///         for Chainlink checkUpkeep, Reactive sweeps, and the keeper bot.
    /// @param fromId cursor to start scanning from
    /// @param limit  max ids to return (scan is bounded at 4x limit records)
    /// @return ids        matured, still-pending swap ids
    /// @return nextCursor pass this as fromId on the next call
    function pendingMatured(uint256 fromId, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 nextCursor)
    {
        uint256 n = nextSwapId;
        uint256 scanCap = limit * 4 + 32;
        uint256[] memory buf = new uint256[](limit);
        uint256 found;
        uint256 i = fromId;
        for (uint256 scanned; i < n && found < limit && scanned < scanCap; (i++, scanned++)) {
            SwapRecord storage r = swaps[i];
            if (r.status == 0 && r.trader != address(0) && _matured(r)) {
                buf[found++] = i;
            }
        }
        nextCursor = i;
        ids = new uint256[](found);
        for (uint256 j; j < found; j++) ids[j] = buf[j];
    }

    function _matured(SwapRecord storage r) internal view returns (bool) {
        HindsightParams storage p = poolParams[r.poolId];
        return currentStamp() >= r.execStamp + p.maturityStamps + p.twapWindowStamps;
    }

    function _doSettle(uint256 swapId, SwapRecord storage r, address keeper) internal {
        HindsightParams memory p = poolParams[r.poolId];
        uint48 nowStamp = currentStamp();
        uint48 windowStart = r.execStamp + p.maturityStamps;
        uint48 windowEnd = windowStart + p.twapWindowStamps;

        SettleData memory sd;
        {
            (bool toxic, uint256 fWad, int256 markoutTicks, int256 thetaTicks, bool graded) =
                _verdict(r, p, nowStamp, windowStart, windowEnd);
            if (r.attributed) {
                _updateReputation(r.trader, markoutTicks, thetaTicks, toxic, graded, p.rampTicks);
            }
            sd = SettleData(swapId, toxic, fWad, keeper, markoutTicks, thetaTicks, graded);
        }
        poolManager.unlock(abi.encode(CallbackOp.SETTLE, abi.encode(sd)));
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
    ) internal view returns (bool toxic, uint256 fWad, int256 markoutTicks, int256 thetaTicks, bool graded) {
        // A FINALIZED verdict outranks the grace deadline. `finalize` is permissionless and
        // callable the instant the window closes, so once the measurement is in the record
        // nothing is left to destroy by waiting — and the grace auto-forfeit exists only to
        // stop toxic flow escaping by outliving the ring buffer. Checking grace first would
        // punish a trader whose swap was measured BENIGN simply because the keeper lane was
        // down for ten minutes: observed live on v5, where five swaps carrying markout 22-27
        // against theta 31 were forfeited in full despite a recorded benign verdict.
        if (r.finalized) {
            markoutTicks = r.fMarkout;
            thetaTicks = r.fTheta;
            fWad = MarkoutLib.forfeitWad(markoutTicks, thetaTicks, int256(p.rampTicks));
            return (fWad > 0, fWad, markoutTicks, thetaTicks, true);
        }
        if (nowStamp > windowEnd + p.graceStamps) {
            // Never measured, and now unmeasurable: punitive, but not a measurement.
            // The keeper tip is suppressed on this branch in `_settleCallback` (see M7).
            return (true, 1e18, 0, 0, false);
        }
        (int24 twapTick,, bool ok) = observations[r.poolId].twap(windowStart, windowEnd, p.maxJumpTicks);
        if (!ok) {
            // Distinguish "we never had data" from "the data existed and was destroyed".
            // Eviction is cheap and permissionless, so rewarding it with a refund would let
            // any toxic trade buy its way out; absent data must still refund, because
            // withholding observations can never be allowed to punish a trader.
            return _noDataVerdict(r.poolId, windowEnd);
        }
        markoutTicks = MarkoutLib.markout(r.execTick, twapTick, r.zeroForOne);
        thetaTicks = _theta(r.poolId, p, windowStart, windowEnd);
        fWad = MarkoutLib.forfeitWad(markoutTicks, thetaTicks, int256(p.rampTicks));
        toxic = fWad > 0;
        graded = true;
    }

    /// @dev Was the window's data destroyed, or did it never exist? Evicting the ring buffer
    ///      is cheap and permissionless, so an evicted window must NOT earn the missing-data
    ///      refund — otherwise any toxic trade can buy its way out. A genuinely dataless
    ///      window still refunds.
    function _noDataVerdict(PoolId id, uint48 windowEnd)
        internal
        view
        returns (bool, uint256, int256, int256, bool)
    {
        (uint48 oldestStamp, bool full) = observations[id].oldest();
        if (full && oldestStamp > windowEnd) {
            return (true, 1e18, 0, 0, false); // evicted: forfeit, ungraded
        }
        return (false, 0, 0, 0, false); // genuinely no data: refund, reputation-neutral
    }

    /// @dev Volatility-scaled toxicity threshold.
    ///
    ///      The volatility input is clamped HARDER than the TWAP (`MAX_VOL_JUMP_TICKS`, not
    ///      `p.maxJumpTicks`), because the two clamps defend opposite parties. The TWAP's
    ///      60-tick clamp protects the TRADER from a manipulated settlement price, so it is
    ///      deliberately loose. Theta's clamp protects the LPs: without it a trader can pad
    ///      their own settlement window with round trips and drive theta to
    ///      `thetaMin + k*maxJumpTicks` = 171 ticks, above the entire realistic markout
    ///      distribution (max 110, p99 = 15 on 55,822 real mainnet swaps) — which acquits
    ///      every trade. At 10 the ceiling is 31 ticks: still above p99, so genuinely
    ///      volatile windows widen theta as intended, but below the tail this exists to catch.
    ///      Found by round-2 audit M4; regression test in test/integration/AuditRepro2.t.sol.
    function _theta(PoolId id, HindsightParams memory p, uint48 windowStart, uint48 windowEnd)
        internal
        view
        returns (int256)
    {
        (uint256 vol,) = observations[id].avgAbsJump(windowStart, windowEnd, MAX_VOL_JUMP_TICKS);
        return int256(uint256(int256(p.thetaMinTicks))) + int256(vol * p.thetaVolMultX10 / 10);
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
        // No tip on an UNGRADED forfeit (a lapse past grace, or an evicted window). Those
        // pay the maximum forfeit, so tipping them would make waiting out the grace period
        // strictly more profitable for a keeper than settling promptly — measured at 20x on
        // a benign bond. With the tip suppressed, prompt settlement weakly dominates for
        // every swap, and the lapsed bond still goes to the LPs in full. (Round-2 audit M7.)
        uint128 tip = s.graded ? uint128(uint256(forfeit) * p.keeperTipBps / 10_000) : 0;
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

    /// @notice Lock in a swap's verdict as soon as its settlement window closes.
    /// @dev Permissionless and cheap. This exists because the observation buffer is finite
    ///      and `poke()` is permissionless: without it, a toxic trader could flood the ring
    ///      buffer after their window closed, destroy the observations that convicted them,
    ///      and have `settle()` fall through to the missing-data refund. Finalising while the
    ///      data still exists removes that race entirely. Keepers call this; `settle` also
    ///      calls it implicitly, so the normal path is unchanged.
    function finalize(uint256 swapId) public {
        SwapRecord storage r = swaps[swapId];
        if (r.trader == address(0)) revert UnknownSwap();
        if (r.finalized || r.status != 0) return;
        HindsightParams memory p = poolParams[r.poolId];
        uint48 windowStart = r.execStamp + p.maturityStamps;
        uint48 windowEnd = windowStart + p.twapWindowStamps;
        if (currentStamp() < windowEnd) revert NotMatured();

        (int24 twapTick,, bool ok) = observations[r.poolId].twap(windowStart, windowEnd, p.maxJumpTicks);
        if (!ok) return; // genuinely no data yet — nothing to lock
        r.fMarkout = int24(MarkoutLib.markout(r.execTick, twapTick, r.zeroForOne));
        r.fTheta = int24(_theta(r.poolId, p, windowStart, windowEnd));
        r.finalized = true;
    }

    /// @notice Permissionless price checkpoint for quiet pools during settlement windows.
    function poke(PoolKey calldata key) external {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        observations[id].write(currentStamp(), tick);
    }

    /// @notice Manipulation-cost bond cap (spec A3): never escrow more than it costs an
    ///         attacker to move the settlement TWAP by the toxicity threshold.
    ///         cap ≈ κ · L_active · θ_min, linearized: moving the pool θ ticks with
    ///         active liquidity L costs ≈ L·sqrtP·θ·1e-4 in token1 (or L/sqrtP·θ·1e-4
    ///         in token0); κ = ½ is folded into the 20_000 denominator. Thin pools thus
    ///         degrade toward a plain low-fee pool instead of becoming manipulable.
    /// @dev Returns 0 (= no cap in BondMathLib) when active liquidity is zero — which
    ///      happens for swaps that exit the initialized range. Those pay the standard
    ///      uncapped bond deliberately: a range-exiting fill realizes maximal price
    ///      movement (maximal markout exposure), and capping it against zero edge
    ///      liquidity would let toxic flow dodge bonds by overshooting the range.
    function _bondCap(PoolId id, bool isCurrency0, int24 thetaMinTicks)
        internal
        view
        returns (uint256 cap)
    {
        uint128 liq = poolManager.getLiquidity(id);
        if (liq == 0 || thetaMinTicks <= 0) return 0;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint256 perTick = isCurrency0
            ? FullMath.mulDiv(liq, 1 << 96, sqrtPriceX96)
            : FullMath.mulDiv(liq, sqrtPriceX96, 1 << 96);
        cap = perTick * uint256(uint24(thetaMinTicks)) / 20_000;
    }

    // ────────────────────────────────── reputation ─────────────────────────────────
    /// @dev The earned discount is only available on pools that explicitly configure a
    ///      `sizeTierCap` (the whale guard). With the safe default of 0 the discount is off
    ///      entirely and only penalties apply — so "no reputation laundering" holds by
    ///      construction rather than by configuration.
    function _bondMultiplier(address trader, uint128 sizeTierCap) internal view returns (uint256 m) {
        m = ToxicityLib.multiplier(
            toxicityScore[trader], MULT_M0_WAD, MULT_SLOPE_WAD, MULT_MIN_WAD, MULT_MAX_WAD
        );
        // Earned benign-history discount (only applies when no toxicity penalty is active).
        if (m == MULT_M0_WAD && sizeTierCap != 0) {
            uint256 discount = uint256(benignSettles[trader]) * DISCOUNT_PER_SETTLE_WAD;
            uint256 floor_ = DISCOUNT_FLOOR_WAD;
            m = discount + floor_ >= MULT_M0_WAD ? floor_ : MULT_M0_WAD - discount;
        }
    }

    /// @dev Reputation must never launder a forfeiture. An auto-forfeit at grace is ungraded
    ///      (no measurement exists) but is still a forfeiture, so it wipes the discount and
    ///      books a fixed toxicity charge — otherwise a keeper maximising its tip by waiting
    ///      for grace would also be the path that erases the trader's record. An ungraded
    ///      REFUND (missing data) stays perfectly neutral, preserving the rule that
    ///      withholding observations can never punish a trader.
    function _updateReputation(
        address trader,
        int256 markoutTicks,
        int256 thetaTicks,
        bool toxic,
        bool graded,
        int24 rampTicks
    ) internal {
        uint256 raw = 0;
        if (toxic) {
            raw = (graded && markoutTicks > thetaTicks)
                ? uint256(markoutTicks - thetaTicks)
                : uint256(uint24(rampTicks));
            benignSettles[trader] = 0; // ANY forfeiture resets the earned discount
        } else if (graded) {
            unchecked {
                if (benignSettles[trader] < type(uint32).max) benignSettles[trader]++;
            }
        } else {
            return; // ungraded refund: fully neutral
        }
        toxicityScore[trader] = ToxicityLib.update(toxicityScore[trader], raw, EMA_LAMBDA_WAD);
    }

    /// @notice Resolve the bond's beneficiary and whether that attribution is trustworthy.
    /// @dev `hookData` is attacker-controlled calldata, so it must never be able to write
    ///      reputation onto a third party (poisoning) or borrow their discount. Refunds may
    ///      still be directed anywhere — the payer is spending their own money — but
    ///      reputation is only read/written when `authenticated` is true:
    ///        * `beneficiary == tx.origin` — self-attribution: the address that actually
    ///          signed this transaction naming itself. tx.origin is used here purely as
    ///          "did this address participate", never as an authorization grant; the worst a
    ///          phisher achieves is attributing a swap to themselves.
    ///        * a whitelisted router vouching via the v4 `IMsgSender` standard (the path for
    ///          smart-contract/AA wallets, whose tx.origin is a bundler).
    ///      Unauthenticated flow simply pays the full default bond and neither earns nor
    ///      suffers reputation.
    function _resolveTrader(address sender, bytes calldata hookData)
        internal
        view
        returns (address beneficiary, bool authenticated)
    {
        if (trustedRouters[sender]) {
            try IMsgSender(sender).msgSender() returns (address u) {
                if (u != address(0)) return (u, true);
            } catch {}
        }
        if (hookData.length >= 32) {
            address t = abi.decode(hookData, (address));
            if (t == tx.origin) return (t, true);
        }
        // Unauthenticated. The bond is withheld from the swap's own output, so it is
        // tx.origin's money — and the refund must follow the money. Returning the hookData
        // address here would let any solver or frontend that builds the calldata skim the
        // bond of a user who signed the transaction; returning `sender` would strand the
        // refund inside a router whose call ended long before the settlement window closed.
        return (tx.origin, false);
    }

    function setTrustedRouter(address router, bool trusted) external {
        if (msg.sender != owner) revert NotOwner();
        trustedRouters[router] = trusted;
        emit TrustedRouterSet(router, trusted);
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

    /// @notice Retune a pool's parameters within hard bounds.
    /// @dev Params are read at SETTLE time, so any change is retroactive over in-flight
    ///      bonds. The bounds below are what makes that safe: the owner can never (a) push
    ///      more than 10% of a forfeit to itself, (b) construct a universal 100% forfeit
    ///      (thetaMin/ramp >= 1), or (c) mature-and-grace pending swaps instantly
    ///      (grace >= window, window >= 1).
    function setParams(PoolId id, HindsightParams calldata p) external {
        if (msg.sender != owner) revert NotOwner();
        HindsightParams memory old = poolParams[id];
        if (
            p.bondBps > 100 || p.keeperTipBps > 1000 || p.twapWindowStamps == 0
                || p.maturityStamps > 600 || p.thetaMinTicks < 1 || p.rampTicks < 1
                || p.maxJumpTicks < 1 || p.epochStamps == 0 || p.graceStamps < p.twapWindowStamps
                // theta_min is the floor of the toxicity threshold; unbounded above, the owner
                // could set it past every possible markout and switch the mechanism off.
                || p.thetaMinTicks > 1000
                // Params are read at SETTLE time, so shortening the settlement deadline would
                // retroactively push already-escrowed bonds past grace and auto-forfeit them
                // at 100%, bypassing theta and the ramp entirely. The deadline may only ever
                // move later. (Round-2 audit M6.)
                || uint256(p.maturityStamps) + p.twapWindowStamps + p.graceStamps
                    < uint256(old.maturityStamps) + old.twapWindowStamps + old.graceStamps
        ) revert BadParams();
        poolParams[id] = p;
    }

    /// @notice Two-step ownership transfer (renounce by transferring to a burn address that
    ///         can never accept — or simply never accepting).
    function transferOwnership(address to) external {
        if (msg.sender != owner) revert NotOwner();
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Bond quote for a prospective swap (frontend preview). Conservative: uses
    ///         the smaller of the two per-side manipulation-cost caps.
    function previewBond(PoolId id, address trader, uint256 unspecifiedAmount)
        external
        view
        returns (uint256)
    {
        HindsightParams memory p = poolParams[id];
        uint256 cap0 = _bondCap(id, true, p.thetaMinTicks);
        uint256 cap1 = _bondCap(id, false, p.thetaMinTicks);
        uint256 cap = cap0 < cap1 ? cap0 : cap1;
        return BondMathLib.bond(
            unspecifiedAmount, p.bondBps, _bondMultiplier(trader, p.sizeTierCap), p.sizeTierCap, cap
        );
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
        if (r.finalized) {
            markoutTicks = r.fMarkout;
            thetaTicks = r.fTheta;
            forfeitWad_ = MarkoutLib.forfeitWad(markoutTicks, thetaTicks, int256(p.rampTicks));
            return (matured, true, markoutTicks, thetaTicks, forfeitWad_);
        }
        (int24 twapTick,, bool ok) = observations[r.poolId].twap(windowStart, windowEnd, p.maxJumpTicks);
        dataOk = ok;
        if (ok) {
            markoutTicks = MarkoutLib.markout(r.execTick, twapTick, r.zeroForOne);
            thetaTicks = _theta(r.poolId, p, windowStart, windowEnd);
            forfeitWad_ = MarkoutLib.forfeitWad(markoutTicks, thetaTicks, int256(p.rampTicks));
        }
    }

    function getSwap(uint256 swapId) external view returns (SwapRecord memory) {
        return swaps[swapId];
    }

    function observationCount(PoolId id) external view returns (uint16) {
        return observations[id].count;
    }

    function newestObservation(PoolId id) external view returns (uint48 stamp, int24 tick, bool ok) {
        return observations[id].newest();
    }
}
