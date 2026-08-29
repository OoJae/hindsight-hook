// Chunked getLogs that respects Unichain Sepolia's 10k-block range cap.
export async function getLogsChunked(pub, { address, event, lookback = 200_000, chunk = 9_500 }) {
  const latest = await pub.getBlockNumber();
  const start = latest > BigInt(lookback) ? latest - BigInt(lookback) : 0n;
  const out = [];
  for (let from = start; from <= latest; from += BigInt(chunk) + 1n) {
    const to = from + BigInt(chunk) > latest ? latest : from + BigInt(chunk);
    try {
      const logs = await pub.getContractEvents({ address, abi: [event], eventName: event.name, fromBlock: from, toBlock: to });
      out.push(...logs);
    } catch (e) {
      // shrink-and-retry once for stricter providers
      const mid = from + (to - from) / 2n;
      try {
        out.push(...await pub.getContractEvents({ address, abi: [event], eventName: event.name, fromBlock: from, toBlock: mid }));
        out.push(...await pub.getContractEvents({ address, abi: [event], eventName: event.name, fromBlock: mid + 1n, toBlock: to }));
      } catch { /* skip this window */ }
    }
  }
  return out;
}
