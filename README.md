# Exit Before the Freeze

**Pauses protect protocols. Exit protects people.**

A keeper-free emergency exit for ordinary lenders. A [Reactive Network](https://reactive.network) contract watches lending pools, bridge adapters and big wallets on **Base Sepolia** and **Unichain Sepolia**. When the warning signs of a hack-driven run appear, it pulls shielded deposits out on **both chains** within seconds, before the pool hits 100% utilization or the market freezes. Nothing off-chain sits on the fast path.

## Status

The full on-chain loop runs on testnet: an origin event on Base, a reaction on Reactive Lasna, and a callback landing on Base **and** Unichain. Two recorded runs:

| Run | Trigger | Result | Latency |
|---|---|---|---|
| 1 | Pool freeze on Base (T5) | Callbacks land on both hubs | Base 2.0 s · Unichain ~4 s |
| 2 | Bridge-collateral drain on Base (T2) | 1,000 mUSDC exits a Shield **on Unichain** to its owner | Base 1.8 s · Unichain 3 s |

Every transaction hash is in [docs/demo-txs.md](docs/demo-txs.md).

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
| ShieldHub | `0x4b883e74b93641ad71517C5E5932F3cc0bcD1A6D` | `0x7511C14935D5C29cDd2bB64d89AFf7C8A9fC345d` |
| MockLendingPool | `0x7511C14935D5C29cDd2bB64d89AFf7C8A9fC345d` | `0xD72eF66a42f9215B775c07a2ECf6A92BCBDBA7EE` |
| MockBridgeAdapter | `0xA53c012fe5dbC2b718671a9AF6D1c1F081b93BE7` | `0xD8e1711EF33094F5bE9aF5bB5C14C259ed9983eE` |

ExitSentinel on Reactive Lasna (5318007): `0x9f5Cb5cd9359a3161949Fd05700a2e5517F0586c`

The full address lists are in [deployments/](deployments/). (`0x7511…` really is the pool on Base and the hub on Unichain; that's a nonce coincidence.)

## Run it

```bash
git clone --recursive https://github.com/lyon-zas/Exit-before-freeze.git
cd Exit-before-freeze/contracts
forge test          # 39 tests: unit, fuzz, an invariant ("funds only reach the owner"), Sentinel triggers
```

To deploy your own, use one funded key on all three chains:

```bash
forge script script/DeployOrigin.s.sol   --rpc-url https://sepolia.base.org     --account deployer --broadcast
forge script script/DeployOrigin.s.sol   --rpc-url https://sepolia.unichain.org --account deployer --broadcast
forge script script/DeploySentinel.s.sol --rpc-url https://lasna-rpc.rnk.dev    --account deployer --broadcast
# then run the two setSentinel commands it prints
forge script script/SeedShield.s.sol     --rpc-url <chain rpc>                  --account deployer --broadcast
```

Built on [`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni). The older `reactive-lib` still deploys, but its subscriptions never activate.

## Repo layout

```
contracts/src/origin/     MockERC20, MockLendingPool, MockBridgeAdapter, RiskOracle, ShieldHub, Shield
contracts/src/reactive/   ExitSentinel
contracts/script/         DeployOrigin, DeploySentinel, SeedShield
contracts/test/           Pool, Shield (+ fuzz), ShieldInvariant, Sentinel
deployments/              addresses per chain (legacy-lib/ = an earlier deploy on the old library, unused)
docs/                     demo transactions and latency
```

## Roadmap

Replay scripts for the Oct 29 Binance and Apr 18 rsETH incidents · AI risk agent and Telegram alerts · Next.js dashboard with a live latency meter.
