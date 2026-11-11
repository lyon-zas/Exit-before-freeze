// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../src/origin/MockERC20.sol";
import {MockLendingPool} from "../src/origin/MockLendingPool.sol";
import {MockBridgeAdapter} from "../src/origin/MockBridgeAdapter.sol";
import {ShieldHub} from "../src/origin/ShieldHub.sol";
import {Shield} from "../src/origin/Shield.sol";

/// Incident replays, one step per call. The sender plays every role: hot wallet, attacker,
/// a shielded lender (their Shield) and an unshielded lender (their direct pool deposit).
/// Steps are separate because a broadcast can't wait for the Sentinel's callback mid-run.
///
///   R="--rpc-url https://sepolia.base.org --account deployer --broadcast"
///   forge script script/Replay.s.sol --sig "reset()"   $R   # re-arm, repay, unfreeze, adapter baseline
///   forge script script/Replay.s.sol --sig "seed()"    $R   # 1,000 shielded + 1,000 unshielded
///   forge script script/Replay.s.sol --sig "binance()" $R   # Oct 29: hot-wallet outflow (T6), borrow burst (T1)
///   forge script script/Replay.s.sol --sig "rseth()"   $R   # Apr 18: adapter drained 99.8% (T2)
///   forge script script/Replay.s.sol --sig "drain()"   $R   # attacker takes the rest: pool at 100%
///
/// Wait for the exit (a few seconds) between the attack step and drain().
contract Replay is Script {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant DEPOSIT = 1_000e6;
    uint256 constant ADAPTER_BASELINE = 116_723 ether; // rsETH adapter before Apr 18
    uint256 constant HOT_WALLET_OUTFLOW = 50_000 ether; // > Sentinel's 10,000 limit

    MockERC20 usdc;
    MockERC20 weth;
    MockERC20 rsToken;
    MockLendingPool pool;
    MockBridgeAdapter adapter;
    ShieldHub hub;
    address hotWallet;

    function _load() internal {
        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".json"));
        usdc = MockERC20(vm.parseJsonAddress(j, ".usdc"));
        weth = MockERC20(vm.parseJsonAddress(j, ".weth"));
        rsToken = MockERC20(vm.parseJsonAddress(j, ".rseth"));
        pool = MockLendingPool(vm.parseJsonAddress(j, ".pool"));
        adapter = MockBridgeAdapter(vm.parseJsonAddress(j, ".adapter"));
        hub = ShieldHub(payable(vm.parseJsonAddress(j, ".hub")));
        hotWallet = vm.parseJsonAddress(j, ".hotWallet");
    }

    /// Ends the last incident and gives the Sentinel fresh baselines.
    function reset() external {
        _load();
        vm.startBroadcast();
        hub.rearm(); // first, so the repay below isn't treated as returning liquidity
        uint256 debt = pool.borrowed(msg.sender);
        if (debt > 0) {
            usdc.mint(msg.sender, debt);
            usdc.approve(address(pool), debt);
            pool.repay(debt);
        }
        if (pool.frozen()) pool.unfreeze();
        uint256 bal = rsToken.balanceOf(address(adapter));
        if (bal < ADAPTER_BASELINE) rsToken.mint(address(adapter), ADAPTER_BASELINE - bal);
        adapter.sync(); // T2 compares against the last balance it saw
        vm.stopBroadcast();
        _report();
    }

    function seed() external {
        _load();
        vm.startBroadcast();
        Shield s = hub.shieldOf(msg.sender);
        if (address(s) == address(0)) s = hub.createShield();
        usdc.mint(msg.sender, 2 * DEPOSIT);
        usdc.approve(address(s), DEPOSIT);
        s.deposit(DEPOSIT); // shielded
        usdc.approve(address(pool), DEPOSIT);
        pool.supply(DEPOSIT); // unshielded
        vm.stopBroadcast();
        _report();
    }

    /// Oct 29: 167k ETH leaves the hot wallet, then fast borrowing. T6 lowers T1 from 20% to 10%,
    /// and the burst stops at 12%: it only trips because the hot-wallet signal came first.
    function binance() external {
        _load();
        require(msg.sender == hotWallet, "sender must be the deployment's hotWallet");
        vm.startBroadcast();
        if (weth.balanceOf(msg.sender) < HOT_WALLET_OUTFLOW) weth.mint(msg.sender, HOT_WALLET_OUTFLOW);
        weth.transfer(DEAD, HOT_WALLET_OUTFLOW);
        uint256 chunk = (pool.available() * 6) / 100;
        pool.borrow(chunk);
        pool.borrow(chunk);
        vm.stopBroadcast();
        _report();
    }

    /// Apr 18: the bridge adapter backing rsETH goes from 116,723 to ~223 in one block.
    function rseth() external {
        _load();
        vm.startBroadcast();
        adapter.release(DEAD, (rsToken.balanceOf(address(adapter)) * 998) / 1000);
        vm.stopBroadcast();
        _report();
    }

    /// The attacker borrows everything left: whoever didn't exit is stuck at 100% utilization.
    function drain() external {
        _load();
        vm.startBroadcast();
        uint256 avail = pool.available();
        if (avail > 0) pool.borrow(avail);
        vm.stopBroadcast();
        _report();
    }

    function _report() internal view {
        address me = msg.sender;
        Shield s = hub.shieldOf(me);
        console.log("pool utilization bps", pool.utilizationBps());
        console.log("pool available      ", pool.available());
        console.log("unshielded supplied ", pool.supplied(me));
        if (address(s) != address(0)) console.log("shielded supplied   ", s.supplied());
        console.log("wallet usdc         ", usdc.balanceOf(me));
    }
}
