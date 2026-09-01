// Chunked getLogs that respects Unichain Sepolia's 10k-block range cap.
//
// This used to walk a rolling 200k-block window one request at a time, and /lp
// reloaded the document every 20s. Twenty-two sequential windows is ~19s, so the
// reload aborted the scan a beat before it resolved — every load, forever. The
// page had its data and destroyed it on a timer.
//
// Two rules this file now holds to, both learned from that bug:
//
//   1. A window that could not be read is COUNTED, never swallowed. The old
//      version had a bare `catch {}`, so a provider having a bad minute produced
//      a confidently wrong total instead of a number the caller could caveat.
//
//   2. There is no silent fallback. A rolling window used to stand in whenever
//      the anchor looked wrong, which reads as prudent and is not: if the anchor
//      is wrong the rolling scan is wrong too, and it fails by rendering a
//      plausible zero rather than by saying anything. A visible error beats a
//      fabricated total, so a bad anchor throws.

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
 * Read one event's logs over [fromBlock, latest] in provider-sized windows.
 *
 * `latest` is passed in rather than fetched here so that concurrent scans share
 * one head — two scans resolving against two different heads would compare
 * totals drawn from different chain states.
 *
 * @returns {Promise<{logs: object[], failed: number, windows: number}>}
 *   `logs` ascending by block. `failed` counts windows that could not be read at
 *   all; when it is non-zero `logs` is incomplete and any total derived from it
 *   is a lower bound. The caller is expected to say so.
 */
export async function getLogsChunked(pub, { address, event, fromBlock, latest, chunk = 9_500 }) {
  if (typeof fromBlock !== "bigint" || fromBlock < 0n) {
    throw new Error(`getLogsChunked: unusable fromBlock (${fromBlock}). Check NEXT_PUBLIC_HOOK_BLOCK.`);
  }
  if (fromBlock > latest) return { logs: [], failed: 0, windows: 0 }; // nothing new since the last scan

  const step = BigInt(chunk) + 1n;
  const windows = [];
  for (let from = fromBlock; from <= latest; from += step) {
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
      // Serialised, not Promise.all'd — a worker slot must never hold two
      // requests, or a rate-limit burst that drops all six workers into this
      // path at once would put twelve extra requests on the wire at the exact
      // moment the endpoint is already refusing them.
      const mid = from + (to - from) / 2n;
      try {
        const a = await read(from, mid);
        const b = await read(mid + 1n, to);
        return [...a, ...b];
      } catch {
        // One more attempt after a pause, for the ordinary dropped connection.
        await new Promise((r) => setTimeout(r, 600));
        try {
          return await read(from, to);
        } catch {
          return null; // counted, not hidden
        }
      }
    }
  });

  // Placed by window index, so concatenating in order preserves block order even
  // though the requests resolved out of order.
  const logs = [];
  let failed = 0;
  for (const r of results) {
    if (r === null) failed++;
    else logs.push(...r);
  }
  return { logs, failed, windows: windows.length };
}

/** Retry a single RPC read once. The head lookup gates every window behind it,
 *  so leaving it as the one unprotected call would let a single dropped request
 *  cost the page a whole refresh cycle. */
export async function withRetry(fn, pauseMs = 600) {
  try {
    return await fn();
  } catch {
    await new Promise((r) => setTimeout(r, pauseMs));
    return fn();
  }
}
