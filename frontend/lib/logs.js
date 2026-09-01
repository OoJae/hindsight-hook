// Chunked getLogs that respects Unichain Sepolia's 10k-block range cap.
//
// This used to walk a rolling 200k-block window one request at a time. Both
// halves of that were wrong.
//
// The window was arbitrary: the interesting range is "since the hook was
// deployed", which is a fixed lower bound, not a distance behind the head. A
// rolling window silently starts dropping the earliest settlements the moment
// the chain outruns it — and it scans a stretch of chain older than the
// contract on every single load until it does.
//
// Sequential was worse. Twenty-two windows at ~880ms is ~19s, and /lp used to
// reload itself every 20s, so the scan was aborted a beat before it resolved,
// every time, forever. The page could not display a settlement it had in fact
// fetched. Bounded parallelism turns that into ~3s.
//
// Failures are returned rather than swallowed. The old version had a bare
// `catch {}` on the retry path, so a provider having a bad minute produced a
// confidently wrong total instead of a number the page could caveat.

const CONCURRENCY = 6;

async function mapPool(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i]);
      }
    }),
  );
  return out;
}

/**
 * @returns {Promise<{logs: object[], failed: number, windows: number}>}
 *   `logs` is in ascending block order. `failed` counts windows that could not
 *   be read at all, which means `logs` is incomplete and any total derived from
 *   it is a lower bound.
 */
export async function getLogsChunked(
  pub,
  { address, event, fromBlock = 0n, lookback = 200_000, chunk = 9_500 },
) {
  const latest = await pub.getBlockNumber();

  // fromBlock is the contract's deployment block when we know it. Fall back to
  // the rolling window if it is missing or implausible (a redeployed hook whose
  // block was never updated would otherwise scan from the wrong era, or from
  // ahead of the head and find nothing).
  const anchor =
    fromBlock > 0n && fromBlock <= latest
      ? fromBlock
      : latest > BigInt(lookback)
        ? latest - BigInt(lookback)
        : 0n;

  const step = BigInt(chunk) + 1n;
  const windows = [];
  for (let from = anchor; from <= latest; from += step) {
    windows.push([from, from + BigInt(chunk) > latest ? latest : from + BigInt(chunk)]);
  }

  const read = (from, to) =>
    pub.getContractEvents({ address, abi: [event], eventName: event.name, fromBlock: from, toBlock: to });

  const results = await mapPool(windows, CONCURRENCY, async ([from, to]) => {
    try {
      return await read(from, to);
    } catch {
      // Shrink and retry: some providers cap by response size rather than by
      // range, so a narrower window can succeed where the full one did not.
      const mid = from + (to - from) / 2n;
      try {
        const [a, b] = await Promise.all([read(from, mid), read(mid + 1n, to)]);
        return [...a, ...b];
      } catch {
        // One more attempt after a pause. Twelve concurrent requests against a
        // public endpoint means the occasional dropped connection is normal
        // rather than exceptional, and a blip should not cost the page a window
        // for the next twenty seconds.
        await new Promise((r) => setTimeout(r, 600));
        try {
          return await read(from, to);
        } catch {
          return null; // counted, not hidden
        }
      }
    }
  });

  // Placed by window index, so concatenating in order preserves block order
  // even though the requests resolved out of order.
  const logs = [];
  let failed = 0;
  for (const r of results) {
    if (r === null) failed++;
    else logs.push(...r);
  }
  return { logs, failed, windows: windows.length };
}
