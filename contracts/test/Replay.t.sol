// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ExitSentinel} from "../src/reactive/ExitSentinel.sol";
import {MockERC20} from "../src/origin/MockERC20.sol";
import {MockLendingPool} from "../src/origin/MockLendingPool.sol";
import {MockBridgeAdapter} from "../src/origin/MockBridgeAdapter.sol";
import {RiskOracle} from "../src/origin/RiskOracle.sol";
import {ShieldHub} from "../src/origin/ShieldHub.sol";
import {Shield} from "../src/origin/Shield.sol";
import {MockSystem} from "./Sentinel.t.sol";

/// End-to-end replays on one chain: real origin contracts emit real events, a relay feeds them to
/// the Sentinel the way Reactive does (same order, same encoding), and the Sentinel's callbacks
/// run on the real hub. Mirrors script/Replay.s.sol step by step.
contract ReplayTest is Test {
    uint256 constant BASE = 84532;
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 constant CALLBACK_SIG = keccak256("CallbackRequested(uint256,address,uint64,bytes)");

    MockERC20 usdc;
    MockERC20 weth;
    MockERC20 rseth;
    MockLendingPool pool;
    MockBridgeAdapter adapter;
    ShieldHub hub;
    ExitSentinel sentinel;
    Shield shield;
    address proxy = makeAddr("callbackProxy");
    address me = address(this); // hot wallet, attacker, shielded and unshielded lender

    function setUp() public {
        vm.chainId(BASE);
        vm.etch(SYSTEM, address(new MockSystem()).code);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        weth = new MockERC20("Mock WETH", "mWETH", 18);
        rseth = new MockERC20("Mock rsETH", "mrsETH", 18);
        pool = new MockLendingPool(usdc);
        adapter = new MockBridgeAdapter(rseth);
        RiskOracle oracle = new RiskOracle(me);
        hub = new ShieldHub(proxy, pool);

        ExitSentinel.Market[2] memory mk;
        mk[0] = ExitSentinel.Market(BASE, address(pool), address(usdc), address(adapter), address(oracle), address(hub), address(weth), me);
        mk[1] = ExitSentinel.Market(1301, address(0x1001), address(0x1002), address(0x1003), address(0x1004), address(0x1005), address(0x1006), me);
        sentinel = new ExitSentinel(mk, 10_000 ether);
        hub.setSentinel(address(sentinel));
        vm.recordLogs();

        // reset(): adapter baseline
        rseth.mint(address(adapter), 116_723 ether);
        adapter.sync();
        // seed(): 1,000 shielded + 1,000 unshielded
        usdc.mint(me, 2_000e6);
        shield = hub.createShield();
        usdc.approve(address(shield), 1_000e6);
        shield.deposit(1_000e6);
        usdc.approve(address(pool), 1_000e6);
        pool.supply(1_000e6);
        _pump();
    }

    /// Relays every recorded log to the Sentinel, runs the Base callbacks it requests on the hub,
    /// and repeats with whatever those callbacks emitted. Returns the number of callbacks run.
    function _pump() internal returns (uint256 ran) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        while (logs.length > 0) {
            for (uint256 i; i < logs.length; ++i) {
                Vm.Log memory l = logs[i];
                if (l.topics[0] == CALLBACK_SIG) continue;
                IReactive.LogRecord memory r;
                r.chainId = BASE;
                r.contractAddress = l.emitter;
                r.topic0 = uint256(l.topics[0]);
                if (l.topics.length > 1) r.topic1 = uint256(l.topics[1]);
                if (l.topics.length > 2) r.topic2 = uint256(l.topics[2]);
                if (l.topics.length > 3) r.topic3 = uint256(l.topics[3]);
                r.data = l.data;
                r.opCode = l.topics.length;
                if (!_subscribed(r)) continue;
                vm.prank(SYSTEM);
                sentinel.react(r);
            }
            Vm.Log[] memory reqs = vm.getRecordedLogs();
            for (uint256 i; i < reqs.length; ++i) {
                if (reqs[i].topics[0] != CALLBACK_SIG || uint256(reqs[i].topics[1]) != BASE) continue;
                bytes memory payload = abi.decode(reqs[i].data, (bytes));
                address s = address(sentinel);
                assembly { mstore(add(payload, 36), s) } // Reactive stamps the requester's address
                vm.prank(proxy);
                (bool ok,) = address(hub).call(payload);
                assertTrue(ok, "callback reverted");
                ++ran;
            }
            logs = vm.getRecordedLogs();
        }
    }

    /// Same filters as the Sentinel's 8 subscriptions per chain.
    function _subscribed(IReactive.LogRecord memory r) internal view returns (bool) {
        address c = r.contractAddress;
        if (c == address(pool) || c == address(adapter) || c == address(hub)) return true;
        return c == address(weth) && r.topic0 == uint256(keccak256("Transfer(address,address,uint256)"))
            && r.topic1 == uint256(uint160(me));
    }

    function _borrowBurst() internal {
        uint256 chunk = (pool.available() * 6) / 100;
        pool.borrow(chunk);
        pool.borrow(chunk);
    }

    function test_binance_hotWalletThenBurstGetsShieldOut() public {
        weth.mint(me, 50_000 ether);
        weth.transfer(DEAD, 50_000 ether); // T6
        _borrowBurst(); // 12% > 10% (high risk) -> T1
        assertGt(_pump(), 0, "no exit");
        assertEq(shield.supplied(), 0);
        assertEq(usdc.balanceOf(me), 1_000e6 + 2 * ((2_000e6 * 6) / 100));
        assertEq(sentinel.exitReason(), sentinel.R_BORROW_VELOCITY());

        pool.borrow(pool.available()); // drain()
        _pump();
        assertEq(pool.utilizationBps(), 10_000);
        assertEq(pool.supplied(me), 1_000e6, "unshielded deposit stuck");
        assertEq(pool.available(), 0);
    }

    function test_binance_sameBurstWithoutHotWalletSignalDoesNotTrip() public {
        _borrowBurst(); // 12% < 20% (normal)
        assertEq(_pump(), 0);
        assertEq(shield.supplied(), 1_000e6);
    }

    function test_rseth_adapterDrainGetsShieldOut() public {
        adapter.release(DEAD, (rseth.balanceOf(address(adapter)) * 998) / 1000);
        assertGt(_pump(), 0, "no exit");
        assertEq(shield.supplied(), 0);
        assertEq(sentinel.exitReason(), sentinel.R_COLLATERAL_DRAIN());
    }

    function test_resetThenReplayAgain() public {
        pool.freeze();
        _pump();
        assertEq(shield.supplied(), 0);
        // reset(): re-arm first, then repay/unfreeze, then baselines
        hub.rearm();
        pool.unfreeze();
        rseth.mint(address(adapter), 1); // any change is fine; sync re-emits the baseline
        adapter.sync();
        usdc.approve(address(shield), 1_000e6);
        shield.deposit(1_000e6);
        assertEq(_pump(), 0, "re-seeding must not trigger an exit");
        assertFalse(sentinel.exitMode());
        adapter.release(DEAD, (rseth.balanceOf(address(adapter)) * 998) / 1000);
        assertGt(_pump(), 0);
        assertEq(shield.supplied(), 0);
    }
}
