export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL ?? "https://sepolia.unichain.org";
export const HOOK = process.env.NEXT_PUBLIC_HOOK;
export const TOKEN0 = process.env.NEXT_PUBLIC_TOKEN0;
export const TOKEN1 = process.env.NEXT_PUBLIC_TOKEN1;
export const SWAP_ROUTER = process.env.NEXT_PUBLIC_SWAP_ROUTER;
export const POOL_ID = process.env.NEXT_PUBLIC_POOL_ID;

// The block the live hook was deployed in, found by binary-searching eth_getCode
// (recorded in DEPLOYMENTS.md). Event scans anchor here rather than at a rolling
// window: the range of interest is "since this contract existed", which is a
// fixed lower bound, and a rolling window scans a stretch of chain older than the
// contract on every load while silently dropping the earliest settlements once
// the chain outruns it.
//
// null means "configured but unusable", which lib/logs.js turns into a visible
// error. It is deliberately distinct from a missing value: `??` only fires on
// null/undefined, and BigInt("") and BigInt(" ") are both 0n rather than throws,
// so an empty override would otherwise sail through as block zero.
export const HOOK_BLOCK = (() => {
  const raw = (process.env.NEXT_PUBLIC_HOOK_BLOCK ?? "").trim() || "61282455";
  return /^[0-9]+$/.test(raw) ? BigInt(raw) : null;
})();

export const POOL_KEY = {
  currency0: TOKEN0,
  currency1: TOKEN1,
  fee: 500,
  tickSpacing: 10,
  hooks: HOOK,
};

// The LIVE pool parameters, as set by script/02 at deploy time (not the contract's
// _defaultParams, which is what these used to mirror — they had been stale since the
// horizon moved to 10s+5s).
export const MATURITY = 50;   // 10s at 200ms flashblocks
export const WINDOW = 25;     // 5s settlement window

export const hookAbi = [
  { type: "function", name: "currentStamp", stateMutability: "view", inputs: [], outputs: [{ type: "uint48" }] },
  { type: "function", name: "nextSwapId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function", name: "getSwap", stateMutability: "view",
    inputs: [{ type: "uint256" }],
    outputs: [{
      type: "tuple", components: [
        { name: "trader", type: "address" }, { name: "execStamp", type: "uint48" },
        { name: "zeroForOne", type: "bool" }, { name: "status", type: "uint8" },
        { name: "poolId", type: "bytes32" }, { name: "notional", type: "uint128" },
        { name: "bond", type: "uint128" }, { name: "bondIsCurrency0", type: "bool" },
        { name: "execTick", type: "int24" }, { name: "attributed", type: "bool" },
      ],
    }],
  },
  {
    type: "function", name: "previewBond", stateMutability: "view",
    inputs: [{ type: "bytes32" }, { type: "address" }, { type: "uint256" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function", name: "previewSettle", stateMutability: "view",
    inputs: [{ type: "uint256" }],
    outputs: [
      { name: "matured", type: "bool" }, { name: "dataOk", type: "bool" },
      { name: "markoutTicks", type: "int256" }, { name: "thetaTicks", type: "int256" },
      { name: "forfeitWad", type: "uint256" },
    ],
  },
  { type: "function", name: "settle", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] },
  { type: "function", name: "toxicityScore", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "benignSettles", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "address" }], outputs: [{ type: "uint32" }] },
  {
    type: "event", name: "Settled",
    inputs: [
      { indexed: true, name: "swapId", type: "uint256" }, { indexed: true, name: "trader", type: "address" },
      { indexed: false, name: "toxic", type: "bool" }, { indexed: false, name: "markoutTicks", type: "int256" },
      { indexed: false, name: "thetaTicks", type: "int256" }, { indexed: false, name: "refund", type: "uint128" },
      { indexed: false, name: "forfeit", type: "uint128" }, { indexed: false, name: "tip", type: "uint128" },
    ],
  },
  {
    type: "event", name: "SwapRecorded",
    inputs: [
      { indexed: true, name: "swapId", type: "uint256" }, { indexed: true, name: "poolId", type: "bytes32" },
      { indexed: true, name: "trader", type: "address" }, { indexed: false, name: "zeroForOne", type: "bool" },
      { indexed: false, name: "notional", type: "uint128" }, { indexed: false, name: "bond", type: "uint128" },
      { indexed: false, name: "execStamp", type: "uint48" }, { indexed: false, name: "execTick", type: "int24" },
    ],
  },
  {
    type: "event", name: "DonationFlushed",
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" },
      { indexed: false, name: "amount0", type: "uint128" }, { indexed: false, name: "amount1", type: "uint128" },
    ],
  },
];

export const swapRouterAbi = [
  {
    type: "function", name: "swap", stateMutability: "payable",
    inputs: [
      {
        name: "key", type: "tuple", components: [
          { name: "currency0", type: "address" }, { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" }, { name: "tickSpacing", type: "int24" }, { name: "hooks", type: "address" },
        ],
      },
      {
        name: "params", type: "tuple", components: [
          { name: "zeroForOne", type: "bool" }, { name: "amountSpecified", type: "int256" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
      {
        name: "testSettings", type: "tuple", components: [
          { name: "takeClaims", type: "bool" }, { name: "settleUsingBurn", type: "bool" },
        ],
      },
      { name: "hookData", type: "bytes" },
    ],
    outputs: [{ type: "int256" }],
  },
];

export const erc20Abi = [
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [] },
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
];

export const MIN_SQRT_PRICE_PLUS_1 = 4295128740n;
export const MAX_SQRT_PRICE_MINUS_1 = 1461446703485210103287273052203988822378723970341n;
