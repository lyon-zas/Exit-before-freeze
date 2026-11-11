"use client";

import { useEffect, useRef, useState } from "react";
import { createPublicClient, http, type Address, type Hash } from "viem";
import { markets, poolAbi, adapterAbi, hubAbi, wethAbi, shieldAbi } from "./config";

export type FeedItem = {
  key: string;
  m: number; // index into markets
  kind: string; // event name
  block: bigint;
  logIndex: number;
  tx: Hash;
  args: Record<string, unknown>;
  ts?: number; // event's own timestamp (seconds), when it carries one
};

const clients = markets.map((m) => createPublicClient({ chain: m.chain, transport: http(m.rpc) }));
const POLL_MS = 4000;

/** Polls both chains for trigger, exit and re-arm events, incrementally from the last block seen. */
export function useFeed() {
  const [items, setItems] = useState<FeedItem[]>([]);
  const [blockMs, setBlockMs] = useState<Record<string, number>>({}); // `${m}:${block}` -> ms timestamp
  const [error, setError] = useState<string>();
  const last = useRef<(bigint | undefined)[]>(markets.map(() => undefined));
  const seen = useRef(new Set<string>());
  const shields = useRef<Address[][]>(markets.map(() => []));
  const msCache = useRef<Record<string, number>>({});

  useEffect(() => {
    let stop = false;

    async function blockTimeMs(i: number, block: bigint) {
      const k = `${i}:${block}`;
      if (k in msCache.current) return;
      const b = (await clients[i].getBlock({ blockNumber: block })) as { timestamp: bigint; timestampMs?: string };
      // Base exposes timestampMs (200 ms blocks); elsewhere fall back to whole seconds.
      msCache.current[k] = b.timestampMs ? Number(BigInt(b.timestampMs)) : Number(b.timestamp) * 1000;
    }

    async function pollChain(i: number) {
      const m = markets[i];
      const c = clients[i];
      const head = await c.getBlockNumber();
      const from = last.current[i] === undefined ? head - m.blockLookback : last.current[i]! + 1n;
      if (from > head) return [];
      const range = { fromBlock: from, toBlock: head };
      // Public RPCs reject log queries without an address, and ExitExecuted comes from each
      // user's Shield, so keep the hub's Shield list current.
      const count = await c.readContract({ address: m.d.hub, abi: hubAbi, functionName: "shieldCount" });
      for (let k = BigInt(shields.current[i].length); k < count; k++) {
        shields.current[i].push(await c.readContract({ address: m.d.hub, abi: hubAbi, functionName: "shields", args: [k] }));
      }
      const [main, hot, exits] = await Promise.all([
        c.getLogs({
          address: [m.d.pool, m.d.adapter, m.d.hub],
          events: [...poolAbi.filter((x) => x.type === "event"), ...adapterAbi, ...hubAbi.filter((x) => x.type === "event")],
          ...range,
        }),
        c.getLogs({ address: m.d.weth, event: wethAbi[0], args: { from: m.d.hotWallet }, ...range }),
        shields.current[i].length
          ? c.getLogs({ address: shields.current[i], event: shieldAbi.find((x) => x.type === "event" && x.name === "ExitExecuted")!, ...range })
          : Promise.resolve([]),
      ]);
      last.current[i] = head;
      return [...main, ...hot, ...exits].map((l) => {
        const args = (l as unknown as { args: Record<string, unknown> }).args;
        return {
          key: `${i}:${l.transactionHash}:${l.logIndex}`,
          m: i,
          kind: (l as unknown as { eventName: string }).eventName,
          block: l.blockNumber!,
          logIndex: l.logIndex!,
          tx: l.transactionHash!,
          args,
          ts: typeof args.ts === "bigint" ? Number(args.ts) : undefined,
        } satisfies FeedItem;
      });
    }

    async function tick() {
      try {
        const fresh = (await Promise.all(markets.map((_, i) => pollChain(i)))).flat().filter((x) => !seen.current.has(x.key));
        fresh.forEach((x) => seen.current.add(x.key));
        // ERC-20 Transfer carries no ts; take its block's so the feed can order it
        await Promise.all(
          fresh.filter((x) => x.ts === undefined && x.kind === "Transfer").map(async (x) => {
            x.ts = Number((await clients[x.m].getBlock({ blockNumber: x.block })).timestamp);
          }),
        );
        if (fresh.length) {
          // ms timestamps for exits and anything that could be their origin (same ts)
          const exitTs = new Set(fresh.filter((x) => x.kind === "ExitExecuted").map((x) => Number(x.args.originTs)));
          const need = fresh.filter((x) => x.kind === "ExitExecuted" || (x.ts !== undefined && exitTs.has(x.ts)));
          await Promise.all(need.map((x) => blockTimeMs(x.m, x.block)));
          if (!stop) {
            setBlockMs({ ...msCache.current });
            setItems((prev) => [...prev, ...fresh]);
          }
        }
        setError(undefined);
      } catch (e) {
        setError(e instanceof Error ? e.message.split("\n")[0] : String(e));
      }
      if (!stop) timer = setTimeout(tick, POLL_MS);
    }

    let timer = setTimeout(tick, 0);
    return () => {
      stop = true;
      clearTimeout(timer);
    };
  }, []);

  return { items, blockMs, error };
}

export type Exit = {
  item: FeedItem;
  amount: bigint;
  reason: number;
  owner: string;
  onchainS: number; // exitTs - originTs from the event itself
  ms?: number; // origin block -> exit block, when both are on Base (ms timestamps)
  origin?: FeedItem;
};

const TRIGGERS = new Set(["Borrowed", "ReserveFrozen", "AdapterBalance", "ReserveState"]);

/** Pairs each exit with the trigger event that carried its originTs. */
export function exitsWithLatency(items: FeedItem[], blockMs: Record<string, number>): Exit[] {
  return items
    .filter((x) => x.kind === "ExitExecuted")
    .map((x) => {
      const originTs = Number(x.args.originTs);
      const origin = items
        .filter((o) => TRIGGERS.has(o.kind) && o.ts === originTs && (o.m !== x.m || o.block <= x.block))
        .sort((a, b) => Number(a.block - b.block) || a.logIndex - b.logIndex)[0];
      const a = origin && blockMs[`${origin.m}:${origin.block}`];
      const b = blockMs[`${x.m}:${x.block}`];
      // ms only within Base: Unichain blocks carry whole seconds, so cross-chain ms would be invented precision
      const ms = origin && origin.m === 0 && x.m === 0 && a && b ? b - a : undefined;
      return {
        item: x,
        amount: x.args.amount as bigint,
        reason: Number(x.args.reason),
        owner: x.args.owner as string,
        onchainS: Number(x.args.exitTs) - originTs,
        ms,
        origin,
      };
    })
    // block numbers aren't comparable across chains; exit timestamps are
    .sort((p, q) => Number(q.item.args.exitTs) - Number(p.item.args.exitTs) || p.item.m - q.item.m);
}

/** Best timestamp an event carries (seconds), for ordering a mixed-chain feed. */
export const eventTime = (x: FeedItem) =>
  x.ts ?? Number((x.args.exitTs ?? x.args.originTs ?? 0n) as bigint);

export function median(xs: number[]) {
  if (!xs.length) return undefined;
  const s = [...xs].sort((a, b) => a - b);
  const h = Math.floor(s.length / 2);
  return s.length % 2 ? s[h] : (s[h - 1] + s[h]) / 2;
}
