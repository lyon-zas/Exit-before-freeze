"use client";

import { useState } from "react";
import { useAccount, useConnect, useDisconnect, useReadContracts, useReadContract } from "wagmi";
import { switchChain, writeContract, waitForTransactionReceipt, getAccount } from "wagmi/actions";
import { zeroAddress, type Abi, type Address } from "viem";
import {
  markets, wagmiConfig, DEMO_ACCOUNT, SENTINEL, REASONS, fmtUsdc,
  erc20Abi, poolAbi, hubAbi, shieldAbi, type Market, type ChainId,
} from "@/lib/config";
import { useFeed, exitsWithLatency, median, eventTime, type FeedItem } from "@/lib/useFeed";

const DEPOSIT = 1_000_000_000n; // 1,000 mUSDC
const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

export default function Page() {
  const { address, isConnected } = useAccount();
  const viewer = (address ?? DEMO_ACCOUNT) as Address;
  const { items, blockMs, error } = useFeed();
  const exits = exitsWithLatency(items, blockMs);
  const msList = exits.map((e) => e.ms).filter((x): x is number => x !== undefined);
  const secList = exits.map((e) => e.onchainS);
  const lastExit = exits[0];

  return (
    <main className="mx-auto max-w-6xl px-4 py-8 sm:px-6">
      <Header />

      <section className="mt-8 grid gap-4 sm:grid-cols-3">
        <Stat
          label="Last exit"
          value={lastExit ? (lastExit.ms !== undefined ? `${(lastExit.ms / 1000).toFixed(1)} s` : `${lastExit.onchainS} s`) : "—"}
          hint={lastExit ? `${markets[lastExit.item.m].name} · ${REASONS[lastExit.reason] ?? `reason ${lastExit.reason}`}` : "waiting for an exit in the last ~45 min"}
          accent
        />
        <Stat
          label="Median latency, Base"
          value={median(msList) !== undefined ? `${(median(msList)! / 1000).toFixed(1)} s` : "—"}
          hint={`origin block → exit block, ms timestamps · ${msList.length} exit${msList.length === 1 ? "" : "s"}`}
        />
        <Stat
          label="Median latency, on-chain"
          value={median(secList) !== undefined ? `${median(secList)} s` : "—"}
          hint={`exitTs − originTs from ExitExecuted · ${secList.length} exit${secList.length === 1 ? "" : "s"}`}
        />
      </section>

      <p className="mt-3 text-xs text-zinc-500">
        Recorded median across runs: 1.8 s on Base, 3 s on Unichain (see docs/demo-txs.md). Live numbers above cover the last ~45 minutes.
      </p>

      <section className="mt-8">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="text-sm font-medium uppercase tracking-wider text-zinc-400">Positions</h2>
          <span className="text-xs text-zinc-500">
            {isConnected ? <>Your wallet {short(viewer)}</> : <>Demo account {short(viewer)} · connect a wallet to see your own</>}
          </span>
        </div>
        <div className="mt-3 grid gap-4 lg:grid-cols-2">
          {markets.map((m) => (
            <MarketCard key={m.chain.id} m={m} viewer={viewer} canAct={isConnected} />
          ))}
        </div>
      </section>

      <section className="mt-10 grid gap-8 lg:grid-cols-5">
        <div className="lg:col-span-3">
          <h2 className="text-sm font-medium uppercase tracking-wider text-zinc-400">Exits</h2>
          <ExitsTable exits={exits} />
        </div>
        <div className="lg:col-span-2">
          <h2 className="text-sm font-medium uppercase tracking-wider text-zinc-400">Live events</h2>
          <EventFeed items={items} />
          {error && <p className="mt-2 text-xs text-amber-400">RPC: {error}</p>}
        </div>
      </section>

      <footer className="mt-12 border-t border-zinc-800 pt-4 text-xs text-zinc-500">
        ExitSentinel on Reactive Lasna:{" "}
        <a className="font-mono underline decoration-zinc-700 hover:text-zinc-300" href={`https://lasna.reactscan.net/address/${SENTINEL}`} target="_blank" rel="noreferrer">
          {SENTINEL}
        </a>
        . The AI agent can only post a risk score. A Shield can only pay its owner.
      </footer>
    </main>
  );
}

function Header() {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  return (
    <header className="flex flex-wrap items-start justify-between gap-4">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Exit Before the Freeze</h1>
        <p className="mt-1 text-sm text-zinc-400">Pauses protect protocols. Exit protects people.</p>
      </div>
      {isConnected ? (
        <button onClick={() => disconnect()} className="rounded-md border border-zinc-700 px-3 py-1.5 font-mono text-sm hover:bg-zinc-900">
          {short(address!)} · disconnect
        </button>
      ) : (
        <div className="flex flex-col items-start gap-1 sm:items-end">
          <button
            onClick={() => connectors[0] && connect({ connector: connectors[0] })}
            disabled={isPending || !connectors[0]}
            className="rounded-md bg-emerald-500 px-4 py-1.5 text-sm font-medium text-black hover:bg-emerald-400 disabled:opacity-50"
          >
            {isPending ? "Connecting…" : "Connect wallet"}
          </button>
          {error && (
            <p role="alert" className="max-w-xs text-xs text-amber-400 sm:text-right">
              {/provider not found/i.test(error.message)
                ? "No browser wallet found. Install MetaMask to act; everything below works without one."
                : error.message.split("\n")[0]}
            </p>
          )}
        </div>
      )}
    </header>
  );
}

function Stat({ label, value, hint, accent }: { label: string; value: string; hint: string; accent?: boolean }) {
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-4">
      <div className="text-xs uppercase tracking-wider text-zinc-500">{label}</div>
      <div className={`mt-1 font-mono text-3xl tabular-nums ${accent ? "text-emerald-400" : ""}`}>{value}</div>
      <div className="mt-1 text-xs text-zinc-500">{hint}</div>
    </div>
  );
}

function MarketCard({ m, viewer, canAct }: { m: Market; viewer: Address; canAct: boolean }) {
  const chainId = m.chain.id as ChainId;
  const reads = useReadContracts({
    contracts: [
      { address: m.d.pool, abi: poolAbi, functionName: "utilizationBps", chainId },
      { address: m.d.pool, abi: poolAbi, functionName: "available", chainId },
      { address: m.d.pool, abi: poolAbi, functionName: "supplied", args: [viewer], chainId },
      { address: m.d.pool, abi: poolAbi, functionName: "frozen", chainId },
      { address: m.d.hub, abi: hubAbi, functionName: "shieldOf", args: [viewer], chainId },
      { address: m.d.usdc, abi: erc20Abi, functionName: "balanceOf", args: [viewer], chainId },
    ],
    query: { refetchInterval: 4000 },
  });
  const [util, avail, unshielded, frozen, shield, wallet] = (reads.data ?? []).map((r) => r.result) as [
    bigint?, bigint?, bigint?, boolean?, Address?, bigint?,
  ];
  const hasShield = !!shield && shield !== zeroAddress;
  const shielded = useReadContract({
    address: shield,
    abi: shieldAbi,
    functionName: "supplied",
    chainId,
    query: { enabled: hasShield, refetchInterval: 4000 },
  }).data;

  const [busy, setBusy] = useState<string>();
  const [err, setErr] = useState<string>();
  async function run(label: string, calls: { address: Address; abi: Abi; functionName: string; args?: unknown[] }[]) {
    setBusy(label);
    setErr(undefined);
    try {
      // getAccount().chainId is the wallet's real chain (may be unsupported, e.g. mainnet); getChainId() is not
      if (getAccount(wagmiConfig).chainId !== chainId) await switchChain(wagmiConfig, { chainId });
      for (const c of calls) {
        const hash = await writeContract(wagmiConfig, { ...c, chainId } as never);
        await waitForTransactionReceipt(wagmiConfig, { hash, chainId });
      }
      await reads.refetch();
    } catch (e) {
      setErr(e instanceof Error ? e.message.split("\n")[0] : String(e));
    }
    setBusy(undefined);
  }

  const utilPct = util !== undefined ? Number(util) / 100 : undefined;
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-4">
      <div className="flex items-center justify-between">
        <h3 className="font-medium">{m.name}</h3>
        {frozen ? (
          <span className="rounded bg-sky-500/15 px-2 py-0.5 text-xs text-sky-300">Frozen</span>
        ) : utilPct !== undefined && utilPct >= 90 ? (
          <span className="rounded bg-red-500/15 px-2 py-0.5 text-xs text-red-300">Utilization {utilPct}%</span>
        ) : (
          <span className="rounded bg-zinc-800 px-2 py-0.5 text-xs text-zinc-400">Live</span>
        )}
      </div>

      <div className="mt-4">
        <div className="flex justify-between text-xs text-zinc-500">
          <span>Pool utilization</span>
          <span className="font-mono tabular-nums">{utilPct !== undefined ? `${utilPct.toFixed(1)}%` : "—"} · {fmtUsdc(avail)} available</span>
        </div>
        <div className="mt-1 h-2 overflow-hidden rounded bg-zinc-800">
          <div
            className={`h-full ${utilPct !== undefined && utilPct >= 90 ? "bg-red-500" : "bg-zinc-400"}`}
            style={{ width: `${Math.min(utilPct ?? 0, 100)}%` }}
          />
        </div>
      </div>

      <dl className="mt-4 grid grid-cols-3 gap-2 text-sm">
        <Cell label="Shielded" value={hasShield ? fmtUsdc(shielded) : "no Shield"} tone="text-emerald-400" />
        <Cell
          label="Unshielded"
          value={fmtUsdc(unshielded)}
          tone={unshielded && avail === 0n ? "text-red-400" : ""}
          note={unshielded && avail === 0n ? "stuck: 0 available" : undefined}
        />
        <Cell label="Wallet" value={fmtUsdc(wallet)} />
      </dl>

      {canAct && (
        <div className="mt-4 flex flex-wrap gap-2">
          <Btn busy={busy} label="Get 1,000 mUSDC" onClick={() => run("Get 1,000 mUSDC", [
            { address: m.d.usdc, abi: erc20Abi, functionName: "mint", args: [viewer, DEPOSIT] },
          ])} />
          {!hasShield && (
            <Btn busy={busy} label="Create Shield" onClick={() => run("Create Shield", [
              { address: m.d.hub, abi: hubAbi, functionName: "createShield" },
            ])} />
          )}
          {hasShield && (
            <Btn busy={busy} label="Deposit 1,000 shielded" onClick={() => run("Deposit 1,000 shielded", [
              { address: m.d.usdc, abi: erc20Abi, functionName: "approve", args: [shield, DEPOSIT] },
              { address: shield!, abi: shieldAbi, functionName: "deposit", args: [DEPOSIT] },
            ])} />
          )}
          <Btn busy={busy} label="Supply 1,000 unshielded" onClick={() => run("Supply 1,000 unshielded", [
            { address: m.d.usdc, abi: erc20Abi, functionName: "approve", args: [m.d.pool, DEPOSIT] },
            { address: m.d.pool, abi: poolAbi, functionName: "supply", args: [DEPOSIT] },
          ])} />
          {hasShield && !!shielded && (
            <Btn busy={busy} label="Withdraw shielded" onClick={() => run("Withdraw shielded", [
              { address: shield!, abi: shieldAbi, functionName: "withdraw", args: [shielded < (avail ?? 0n) ? shielded : avail ?? 0n] },
            ])} />
          )}
        </div>
      )}
      {busy && <p className="mt-2 text-xs text-zinc-400">{busy}: confirm in your wallet…</p>}
      {err && <p className="mt-2 text-xs text-amber-400">{err}</p>}
      <p className="mt-3 text-xs text-zinc-600">
        Hub <a className="font-mono hover:text-zinc-400" href={`${m.explorer}/address/${m.d.hub}`} target="_blank" rel="noreferrer">{short(m.d.hub)}</a>
        {" · "}Pool <a className="font-mono hover:text-zinc-400" href={`${m.explorer}/address/${m.d.pool}`} target="_blank" rel="noreferrer">{short(m.d.pool)}</a>
        {hasShield && <>{" · "}Shield <a className="font-mono hover:text-zinc-400" href={`${m.explorer}/address/${shield}`} target="_blank" rel="noreferrer">{short(shield!)}</a></>}
      </p>
    </div>
  );
}

function Cell({ label, value, tone = "", note }: { label: string; value: string; tone?: string; note?: string }) {
  return (
    <div>
      <dt className="text-xs text-zinc-500">{label}</dt>
      <dd className={`font-mono tabular-nums ${tone}`}>{value}</dd>
      {note && <dd className="text-[11px] text-red-400/80">{note}</dd>}
    </div>
  );
}

function Btn({ label, onClick, busy }: { label: string; onClick: () => void; busy?: string }) {
  return (
    <button
      onClick={onClick}
      disabled={!!busy}
      className="rounded-md border border-zinc-700 px-3 py-1.5 text-xs hover:bg-zinc-900 disabled:opacity-40"
    >
      {busy === label ? "…" : label}
    </button>
  );
}

function ExitsTable({ exits }: { exits: ReturnType<typeof exitsWithLatency> }) {
  if (!exits.length) return <p className="mt-3 text-sm text-zinc-500">No exits in the last ~45 minutes. Run a replay to see one land.</p>;
  return (
    <div className="mt-3 overflow-x-auto">
      <table className="w-full text-sm">
        <thead className="text-left text-xs text-zinc-500">
          <tr>
            <th className="py-2 pr-3 font-normal">Chain</th>
            <th className="py-2 pr-3 font-normal">Amount</th>
            <th className="py-2 pr-3 font-normal">Reason</th>
            <th className="py-2 pr-3 font-normal">Latency</th>
            <th className="py-2 font-normal">Tx</th>
          </tr>
        </thead>
        <tbody>
          {exits.slice(0, 12).map((e) => {
            const m = markets[e.item.m];
            return (
              <tr key={e.item.key} className="border-t border-zinc-900">
                <td className="py-2 pr-3">{m.name.replace(" Sepolia", "")}</td>
                <td className="py-2 pr-3 font-mono tabular-nums">{fmtUsdc(e.amount)}</td>
                <td className="py-2 pr-3 text-zinc-400">{REASONS[e.reason] ?? e.reason}</td>
                <td className="py-2 pr-3 font-mono tabular-nums text-emerald-400">
                  {e.ms !== undefined ? `${e.ms.toLocaleString()} ms` : `${e.onchainS} s`}
                </td>
                <td className="py-2 font-mono text-xs">
                  <a className="text-zinc-400 hover:text-zinc-200" href={`${m.explorer}/tx/${e.item.tx}`} target="_blank" rel="noreferrer">{short(e.item.tx)}</a>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function describe(x: FeedItem): string {
  const a = x.args;
  switch (x.kind) {
    case "Borrowed": return `Borrowed ${fmtUsdc(a.amount as bigint)} mUSDC`;
    case "ReserveFrozen": return "Market frozen";
    case "AdapterBalance": return `Bridge adapter balance ${(Number(a.balance as bigint) / 1e18).toLocaleString("en-US", { maximumFractionDigits: 0 })} rsETH`;
    case "Transfer": return `Hot wallet sent ${(Number(a.value as bigint) / 1e18).toLocaleString("en-US", { maximumFractionDigits: 0 })} WETH`;
    case "ExitRound": {
      const n = Number(a.processed);
      return `Exit round · ${n} Shield${n === 1 ? "" : "s"} · paid ${fmtUsdc(a.totalPaid as bigint)}`;
    }
    case "ExitExecuted": return `Shield exited ${fmtUsdc(a.amount as bigint)} mUSDC to owner`;
    case "Rearm": return "Sentinel re-armed";
    default: return x.kind;
  }
}

function EventFeed({ items }: { items: FeedItem[] }) {
  const shown = items
    .filter((x) => x.kind !== "ReserveState")
    .sort((a, b) => eventTime(b) - eventTime(a) || a.m - b.m || Number(b.block - a.block) || b.logIndex - a.logIndex)
    .slice(0, 20);
  if (!shown.length) return <p className="mt-3 text-sm text-zinc-500">Listening on Base and Unichain…</p>;
  return (
    <ul className="mt-3 space-y-1.5 text-sm">
      {shown.map((x) => {
        const m = markets[x.m];
        const exit = x.kind === "ExitExecuted" || x.kind === "ExitRound";
        return (
          <li key={x.key} className="flex items-baseline gap-2">
            <span className="w-16 shrink-0 text-xs text-zinc-500">{m.name.replace(" Sepolia", "")}</span>
            <a
              href={`${m.explorer}/tx/${x.tx}`}
              target="_blank"
              rel="noreferrer"
              className={`truncate hover:underline ${exit ? "text-emerald-400" : "text-zinc-300"}`}
            >
              {describe(x)}
            </a>
          </li>
        );
      })}
    </ul>
  );
}
