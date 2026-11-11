# Demo transactions

Runs 1–2 contracts: `deployments/v1/` (built on `reactive-lib-omni`). Sentinel on Lasna: `0x9f5Cb5cd9359a3161949Fd05700a2e5517F0586c`.

## Run 1 — first full loop (T5 freeze on Base, no Shields yet)

| Leg | Chain | Tx | Block | Timestamp |
|---|---|---|---|---|
| Origin: `ReserveFrozen` | Base Sepolia | `0x3b4ca8741f43f2c3e258ca08dd8ad87c51ca31c67a4a68a25d9d69e5c5f84122` | 57304560 | 1794382780.800 |
| Callback: `exitAll` → `ExitRound(5, …)` | Base Sepolia | `0xa4db408aac834a2a3d977cdb31a44a68ae861456c5a0f3366f76756750f68ee5` | 57304570 | 1794382782.800 |
| Callback: `exitAll` → `ExitRound(5, …)` | Unichain Sepolia | `0x3aa2e48a307efa57833e896a0b748b2a57f430a391d4079c2d80fd36657efa02` | 67530356 | 1794382784 |
| Reactive tx | Lasna | _(look up on lasna.reactscan.net for the Sentinel)_ | | |

Latency (origin block → callback block): **Base 2.0 s**, **Unichain ~4 s** (Unichain blocks expose whole seconds only).

## Run 2 — cross-chain exit (T2 collateral drain on Base → Shield exits on Unichain)

Setup: `rearm()` on the Unichain hub (`0x8c713cf86a8642cc559589de82de634b873c00131ee5ec936f2e3d48082bfa1a`), then a Shield with 1,000 mUSDC on Unichain (`0x71152a1911597233a8c66be8c43b64dd6858542984fc2b366a2ec9bfdbaba0ff`).

| Leg | Chain | Tx | Block | Timestamp |
|---|---|---|---|---|
| Origin: `AdapterBalance` 223 → 23 rsETH (−89.7%) | Base Sepolia | `0x45310fce31431b702f9f5ecc7ec936d32da81d454e77d47c0f6b14e7ae7b5dd8` | 57311945 | 1794384257.800 |
| Callback: `ExitRound(2, …)` | Base Sepolia | `0x3267615ec1dc988fe1a1fdb78fa3af28674b92b98f7a8bb85f1b1e9c804c1c34` | 57311954 | +1800 ms |
| Callback: `ExitExecuted` 1,000 mUSDC → owner | Unichain Sepolia | `0x8a732442ced4f0fc54f5c0717d40b616e55a6f3623e6d722153959549d93781d` | 67531832 | 1794384260 |

Latency: **Base 1800 ms**, **Unichain 3 s** (on-chain `exitTs − originTs` from `ExitExecuted`).

Note: the earlier 116,723 → 223 drain (`0x5ca364eb…`) did not trip: the adapter's baseline `sync()` ran before the Sentinel existed, so that drain was the Sentinel's first reading. Replays must call `sync()` after the Sentinel is live.

## Run 3 — Oct 29 Binance replay (T6 hot-wallet outflow → T1 borrow burst)

Contracts: `deployments/` (v2, pool with `unfreeze()`). Sentinel: `0xF3582eAf241E25f705846a2494fF756C1426fee7`. Steps from `script/Replay.s.sol`: `reset()`, `seed()`, `binance()`, `drain()`.

| Leg | Chain | Tx | Block |
|---|---|---|---|
| Hot wallet sends 50,000 WETH out (T6 → high-risk thresholds) | Base Sepolia | `0x3e10229c679453d3e624726c6ff84dff59a6cddaea7461af54e682f8f5ba8a32` | 57347395 |
| Borrow burst 6% + 6% = 12% of liquidity (T1 trips at the 10% high-risk limit) | Base Sepolia | `0xb9760d05c04f6daadca08ca9ef60bcc95b12e6106b3c8af4cc6e847f1099f489`, `0x576990028ef217a0a1777ee82793b64db536c45e67406f5eaccabd9ec3a6f760` | 57347395 |
| **Exit**: `ExitExecuted` 2,000 mUSDC → owner, reason 1 | Base Sepolia | `0x959571e250dcd6b34c77d2ac69ab3a25cec9fe7aa2f8600d1ab1dbd2449644df` | 57347404 |
| Attacker drains the rest: utilization 100% | Base Sepolia | `0x77c5b95397208de750b26444c9ccb4da2bf6272118502c56285e639a6aab7744` | 57349062 |

Latency: **1,800 ms** (block `timestampMs` 1794391347800 → 1794391349600); on-chain `exitTs − originTs` = 2 s.
Outcome: shielded 2,000 mUSDC back in the wallet; unshielded 2,000 mUSDC still supplied with 0 available.
The same 12% burst without the hot-wallet signal does not trip (normal limit 20%) — see `test_binance_sameBurstWithoutHotWalletSignalDoesNotTrip`.

## Run 4 — Apr 18 rsETH replay (T2 collateral drain on Base → exits on Base **and** Unichain)

Steps: `reset()` and `seed()` on Base, `SeedShield` on Unichain, then `rseth()` on Base.

| Leg | Chain | Tx | Block |
|---|---|---|---|
| Bridge adapter 116,723 → 233 rsETH (−99.8%) | Base Sepolia | `0x844a0976481007dd241ed58f1c95d13f84d054e30a774630b76a2846ee7259c8` | 57354371 |
| **Exit**: `ExitExecuted` 1,000 mUSDC → owner, reason 2 | Base Sepolia | `0x9aee63e5e4953333da340ed25c430af4a30f560097bcc055532990c2f515752c` | 57354379 |
| **Exit**: `ExitExecuted` 1,000 mUSDC → owner, reason 2 | Unichain Sepolia | `0x6cd92bd2403ee736dbb75249c3cde1fa95dba4b24bfd89bf0717b777de01cb91` | 67540317 |

Latency: **Base 1,600 ms** (block `timestampMs` 1794392743000 → 1794392744600); **Unichain 2 s** (`exitTs − originTs` in `ExitExecuted`).

## Latency summary

| Run | Base | Unichain |
|---|---|---|
| 1 freeze | 2,000 ms | ~4 s |
| 2 collateral drain | 1,800 ms | 3 s |
| 3 Binance replay | 1,800 ms | — |
| 4 rsETH replay | 1,600 ms | 2 s |
| **Median** | **1,800 ms** | **3 s** |
