# Demo transactions

Contracts: see `deployments/*.json` (built on `reactive-lib-omni`). Sentinel on Lasna: `0x9f5Cb5cd9359a3161949Fd05700a2e5517F0586c`.

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
