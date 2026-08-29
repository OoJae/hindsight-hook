// Hindsight keeper bot
// Duties:
//  1. (testnet only) advance the OperatedFlashblockNumber counter toward wall-clock
//     flashblock cadence (200ms/flashblock), batched every TICK_MS
//  2. poke() the pool during open settlement windows so quiet pools still have TWAP data
//  3. settle() matured swaps (earning tips on forfeits)
//  4. flushDonations() once per epoch
//
// env: RPC_URL, PRIVATE_KEY, HOOK, FLASHBLOCK_NUMBER (optional; own instance only),
//      TOKEN0, TOKEN1, SWAP_ROUTER (unused here), POOL_ID (bytes32), POOL_KEY_* fields
import 'dotenv/config';
import { createPublicClient, createWalletClient, http, parseAbi, parseAbiItem } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const RPC = process.env.RPC_URL ?? 'https://sepolia.unichain.org';
const account = privateKeyToAccount(process.env.PRIVATE_KEY);
const pub = createPublicClient({ transport: http(RPC) });
const wallet = createWalletClient({ account, transport: http(RPC) });

const HOOK = process.env.HOOK;
const FBN = process.env.FLASHBLOCK_NUMBER || null; // only when we operate our own
const TICK_MS = Number(process.env.TICK_MS ?? 4000);
const FLASHBLOCK_MS = 200;

const hookAbi = parseAbi([
  'function currentStamp() view returns (uint48)',
  'function settle(uint256 swapId)',
  'function poke((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key)',
  'function flushDonations(bytes32 id)',
  'function getSwap(uint256) view returns ((address trader,uint48 execStamp,bool zeroForOne,uint8 status,bytes32 poolId,uint128 notional,uint128 bond,bool bondIsCurrency0,int24 execTick))',
  'function nextSwapId() view returns (uint256)',
]);
const fbnAbi = parseAbi([
  'function getFlashblockNumber() view returns (uint256)',
  'function setFlashblockNumber(uint256 n)',
]);

const poolKey = {
  currency0: process.env.TOKEN0,
  currency1: process.env.TOKEN1,
  fee: 500,
  tickSpacing: 10,
  hooks: HOOK,
};
const POOL_ID = process.env.POOL_ID;

// N + W from default params — keep in sync with HindsightParams
const MATURITY = 15, WINDOW = 10;
const genesis = Date.now();
let fbnBase = null;

async function tickCounter() {
  if (!FBN) return;
  if (fbnBase === null) {
    fbnBase = await pub.readContract({ address: FBN, abi: fbnAbi, functionName: 'getFlashblockNumber' });
  }
  const target = fbnBase + BigInt(Math.floor((Date.now() - genesis) / FLASHBLOCK_MS));
  const current = await pub.readContract({ address: FBN, abi: fbnAbi, functionName: 'getFlashblockNumber' });
  if (target > current) {
    const tx = await wallet.writeContract({ address: FBN, abi: fbnAbi, functionName: 'setFlashblockNumber', args: [target] });
    console.log(`[fbn] -> ${target} (${tx.slice(0, 10)})`);
  }
}

const settled = new Set();
async function settleMatured() {
  const now = await pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'currentStamp' });
  const n = await pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'nextSwapId' });
  let pokedThisRound = false;
  for (let id = 0n; id < n; id++) {
    if (settled.has(id)) continue;
    const r = await pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'getSwap', args: [id] });
    if (r.status !== 0) { settled.add(id); continue; }
    const windowEnd = BigInt(r.execStamp) + BigInt(MATURITY + WINDOW);
    if (BigInt(now) < windowEnd) {
      // window still open: guarantee at least one observation lands in it
      if (!pokedThisRound) {
        try {
          const tx = await wallet.writeContract({ address: HOOK, abi: hookAbi, functionName: 'poke', args: [poolKey] });
          console.log(`[poke] window open for #${id} (${tx.slice(0, 10)})`);
          pokedThisRound = true;
        } catch (e) { console.error('[poke] failed:', e.shortMessage ?? e.message); }
      }
      continue;
    }
    try {
      const tx = await wallet.writeContract({ address: HOOK, abi: hookAbi, functionName: 'settle', args: [id] });
      console.log(`[settle] #${id} (${tx.slice(0, 10)})`);
      settled.add(id);
    } catch (e) { console.error(`[settle] #${id} failed:`, e.shortMessage ?? e.message); }
  }
}

let lastFlush = 0;
async function flush() {
  if (!POOL_ID) return;
  if (Date.now() - lastFlush < 15_000) return;
  try {
    const tx = await wallet.writeContract({ address: HOOK, abi: hookAbi, functionName: 'flushDonations', args: [POOL_ID] });
    console.log(`[flush] (${tx.slice(0, 10)})`);
    lastFlush = Date.now();
  } catch (e) { /* epoch-gated no-op reverts are fine */ }
}

console.log(`Hindsight keeper up — hook ${HOOK}, counter ${FBN ?? 'official/fallback'}`);
setInterval(async () => {
  try { await tickCounter(); await settleMatured(); await flush(); }
  catch (e) { console.error('[loop]', e.shortMessage ?? e.message); }
}, TICK_MS);
