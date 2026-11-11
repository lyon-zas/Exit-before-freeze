# Exit Before the Freeze

**Pauses protect protocols. Exit protects people.**

A keeper-free emergency exit for ordinary lenders. A [Reactive Network](https://reactive.network) contract watches lending pools, bridge adapters and big wallets on **Base Sepolia** and **Unichain Sepolia**. When the warning signs of a hack-driven run appear, it pulls shielded deposits out on **both chains** within seconds, before the pool hits 100% utilization or the market freezes. Nothing off-chain sits on the fast path.

## Status

The full on-chain loop runs on testnet: an origin event on Base, a reaction on Reactive Lasna, and a callback landing on Base **and** Unichain. Recorded runs:

| Run | Trigger | Result | Latency |
|---|---|---|---|
| 1 | Pool freeze on Base (T5) | Callbacks land on both hubs | Base 2.0 s · Unichain ~4 s |
| 2 | Bridge-collateral drain on Base (T2) | 1,000 mUSDC exits a Shield **on Unichain** to its owner | Base 1.8 s · Unichain 3 s |
| 3 | **Oct 29 Binance replay**: hot-wallet outflow (T6), then a 12% borrow burst (T1) | Shielded 2,000 mUSDC out; unshielded 2,000 **stuck at 100% utilization** after the drain | **1.8 s** |
| 4 | **Apr 18 rsETH replay**: bridge adapter drained 99.8% on Base (T2) | Shields exit on **Base and Unichain** | Base **1.6 s** · Unichain 2 s |

Median latency from origin block to exit block: **1.8 s on Base** and **3 s on Unichain**. Every transaction hash is in [docs/demo-txs.md](docs/demo-txs.md).

## How it works

```
Base Sepolia / Unichain Sepolia           Reactive Lasna                    Base + Unichain
MockLendingPool  ── ReserveState ──┐
                 ── Borrowed ──────┤
                 ── ReserveFrozen ─┤
MockBridgeAdapter ─ AdapterBalance ┼──▶  ExitSentinel.react()  ──callback──▶ ShieldHub.exitAll()
hot-wallet WETH  ── Transfer ──────┤     (counters + triggers)                └─▶ Shield.emergencyExit()
RiskOracle (AI)  ── RiskLevel ─────┘                                                 └─▶ funds to owner
```

- **Shield** (one per user) supplies to the pool for its owner. Every path that moves funds pays the owner; there's no other recipient.
- **ShieldHub** (one per chain) is the callback target. It accepts `exitAll` only from that chain's Reactive callback proxy, carrying the Sentinel's address.
- **ExitSentinel** (on Lasna) subscribes to 16 event streams, 8 per chain. When any trigger trips, it calls `exitAll` on **both** chains.
- **RiskOracle** is the only thing the AI agent can write to. It can raise or lower thresholds, or call for an exit, but it can never move funds.

| # | Trigger | Fires when (normal / high risk) |
|---|---|---|
| T1 | Borrow velocity | > 20% / 10% of window-start liquidity borrowed within 10 min |
| T2 | Collateral drain | adapter balance drops > 50% / 30% between two events |
| T3 | Utilization | ≥ 90% / 80% |
| T4 | Rate near cap | borrow rate ≥ 85% of the cap |
| T5 | Freeze | any watched market freezes |
| T6 | Hot-wallet outflow | one large transfer: switches to high-risk thresholds for 2 h (no exit by itself) |

## Deployments

| | Base Sepolia (84532) | Unichain Sepolia (1301) |
|---|---|---|
| ShieldHub | `0xca34Af7D9E97F924A3fbce3A4253e07987132Ff4` | `0x4Bf2930766a81A29af81a3C9b882BAAA7F2243FF` |
| MockLendingPool | `0x8de961730eadD1758AeC9E015666d2f5F665303c` | `0xE48be97E4a8D2Df55D7E553A2B303940476e5485` |
| MockBridgeAdapter | `0x62Bd742EF50e314eD3a13Eb9C22c6F2A8A79580a` | `0x8de961730eadD1758AeC9E015666d2f5F665303c` |

ExitSentinel on Reactive Lasna (5318007): `0xF3582eAf241E25f705846a2494fF756C1426fee7`

The full address lists are in [deployments/](deployments/); runs 1–2 used [deployments/v1/](deployments/v1/). (`0x8de9…` really is the pool on Base and the adapter on Unichain; that's a nonce coincidence.)

## Run it

```bash
git clone --recursive https://github.com/lyon-zas/Exit-before-freeze.git
cd Exit-before-freeze/contracts
forge test          # 44 tests: unit, fuzz, an invariant ("funds only reach the owner"), Sentinel triggers
```

To deploy your own, use one funded key on all three chains:

```bash
forge script script/DeployOrigin.s.sol   --rpc-url https://sepolia.base.org     --account deployer --broadcast
forge script script/DeployOrigin.s.sol   --rpc-url https://sepolia.unichain.org --account deployer --broadcast
forge script script/DeploySentinel.s.sol --rpc-url https://lasna-rpc.rnk.dev    --account deployer --broadcast
# then run the two setSentinel commands it prints
forge script script/SeedShield.s.sol     --rpc-url <chain rpc>                  --account deployer --broadcast
```

Replay an incident (one step per call; wait a few seconds after the attack step):

```bash
R="--rpc-url https://sepolia.base.org --account deployer --broadcast"
forge script script/Replay.s.sol --sig "reset()"   $R   # re-arm, repay, unfreeze, fresh baselines
forge script script/Replay.s.sol --sig "seed()"    $R   # 1,000 shielded + 1,000 unshielded
forge script script/Replay.s.sol --sig "binance()" $R   # or "rseth()"
forge script script/Replay.s.sol --sig "drain()"   $R   # attacker takes the rest: unshielded stuck at 100%
```

### Dashboard

```bash
cd web && npm install && npm run dev   # http://localhost:3000
```

Without a wallet it shows the demo account's positions on both chains, a live feed of triggers and exits, and the latency of each exit. On Base the latency comes from millisecond block timestamps; on Unichain it's `exitTs − originTs`. With a wallet connected you can mint test mUSDC, create a Shield, and deposit shielded or unshielded. It reads addresses from `deployments/` and needs no backend.

Built on [`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni). The older `reactive-lib` still deploys, but its subscriptions never activate.

## Repo layout

```
contracts/src/origin/     MockERC20, MockLendingPool, MockBridgeAdapter, RiskOracle, ShieldHub, Shield
contracts/src/reactive/   ExitSentinel
contracts/script/         DeployOrigin, DeploySentinel, SeedShield, Replay
contracts/test/           Pool, Shield (+ fuzz), ShieldInvariant, Sentinel, Replay (end-to-end with a log relay)
web/                      Next.js dashboard (wagmi + viem), reads deployments/ directly
deployments/              addresses per chain (legacy-lib/ = an earlier deploy on the old library, unused)
docs/                     demo transactions and latency
```

## Roadmap

AI risk agent and Telegram alerts · demo video.
