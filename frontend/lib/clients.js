import { createPublicClient, createWalletClient, custom, http } from "viem";
import { RPC_URL } from "./config";

export const chain = {
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
};

export const pub = createPublicClient({ chain, transport: http(RPC_URL) });

export async function getWallet() {
  if (!window.ethereum) throw new Error("no wallet — install MetaMask/Rabby");
  const wallet = createWalletClient({ chain, transport: custom(window.ethereum) });
  const [account] = await wallet.requestAddresses();
  try {
    await wallet.switchChain({ id: chain.id });
  } catch {
    await wallet.addChain({ chain }).catch(() => {});
  }
  return { wallet, account };
}
