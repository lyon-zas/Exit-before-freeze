import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { baseSepolia, unichainSepolia } from "viem/chains";
import { parseAbi, type Address, type Chain } from "viem";
import base from "../../deployments/84532.json";
import uni from "../../deployments/1301.json";
import lasna from "../../deployments/5318007.json";

export type Market = {
  chain: Chain;
  name: string;
  rpc: string;
  explorer: string;
  blockLookback: bigint; // ~45 min of history on first load
  d: {
    usdc: Address;
    weth: Address;
    pool: Address;
    adapter: Address;
    hub: Address;
    hotWallet: Address;
  };
};

export const markets: Market[] = [
  {
    chain: baseSepolia,
    name: "Base Sepolia",
    rpc: "https://base-sepolia-rpc.publicnode.com",
    explorer: "https://sepolia.basescan.org",
    blockLookback: 13_000n, // ~200 ms blocks
    d: base as Market["d"],
  },
  {
    chain: unichainSepolia,
    name: "Unichain Sepolia",
    rpc: "https://unichain-sepolia-rpc.publicnode.com",
    explorer: "https://sepolia.uniscan.xyz",
    blockLookback: 2_700n, // ~1 s blocks
    d: uni as Market["d"],
  },
];

export type ChainId = (typeof wagmiConfig)["chains"][number]["id"];

export const SENTINEL = lasna.sentinel as Address;
// Shown when no wallet is connected: the account the recorded replays ran from.
export const DEMO_ACCOUNT = base.hotWallet as Address;

export const wagmiConfig = createConfig({
  chains: [baseSepolia, unichainSepolia],
  connectors: [injected()],
  transports: {
    [baseSepolia.id]: http(markets[0].rpc),
    [unichainSepolia.id]: http(markets[1].rpc),
  },
  ssr: true,
});

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function mint(address,uint256)",
]);

export const poolAbi = parseAbi([
  "function utilizationBps() view returns (uint256)",
  "function available() view returns (uint256)",
  "function supplied(address) view returns (uint256)",
  "function frozen() view returns (bool)",
  "function supply(uint256)",
  "function withdraw(uint256)",
  "event ReserveState(address indexed asset, uint256 utilizationBps, uint256 borrowRateBps, uint256 available, uint256 ts)",
  "event Borrowed(address indexed asset, address indexed borrower, uint256 amount, uint256 ts)",
  "event ReserveFrozen(address indexed asset, uint256 ts)",
]);

export const adapterAbi = parseAbi(["event AdapterBalance(address indexed token, uint256 balance, uint256 ts)"]);
export const wethAbi = parseAbi(["event Transfer(address indexed from, address indexed to, uint256 value)"]);

export const hubAbi = parseAbi([
  "function shieldOf(address) view returns (address)",
  "function shieldCount() view returns (uint256)",
  "function shields(uint256) view returns (address)",
  "function createShield() returns (address)",
  "event ExitRound(uint8 reason, uint256 originTs, uint256 processed, uint256 totalPaid)",
  "event Rearm(address indexed asset, uint256 ts)",
]);

export const shieldAbi = parseAbi([
  "function supplied() view returns (uint256)",
  "function deposit(uint256)",
  "function withdraw(uint256)",
  "event ExitExecuted(address indexed owner, address indexed asset, uint256 amount, uint8 reason, uint256 originTs, uint256 exitTs)",
]);

export const REASONS: Record<number, string> = {
  1: "Borrow velocity (T1)",
  2: "Collateral drain (T2)",
  3: "Utilization (T3)",
  4: "Rate near cap (T4)",
  5: "Market frozen (T5)",
  7: "AI risk: critical",
};

export const fmtUsdc = (v?: bigint) =>
  v === undefined ? "—" : (Number(v) / 1e6).toLocaleString("en-US", { maximumFractionDigits: 2 });
