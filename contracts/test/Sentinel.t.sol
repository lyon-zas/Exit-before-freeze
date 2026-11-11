// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {ExitSentinel} from "../src/reactive/ExitSentinel.sol";
import {MockERC20} from "../src/origin/MockERC20.sol";
import {MockLendingPool} from "../src/origin/MockLendingPool.sol";
import {ShieldHub} from "../src/origin/ShieldHub.sol";
import {Shield} from "../src/origin/Shield.sol";

/// Stands in for Reactive's system contract at 0x8888...8888.
contract MockSystem {
    event CallbackRequested(uint256 indexed chainId, address indexed recipient, uint64 indexed gasLimit, bytes payload);

    uint256 public subs;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        ++subs;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        emit CallbackRequested(c.chainId, c.recipient, c.gasLimit, c.payload);
    }
}

contract SentinelTest is Test {
    uint256 constant BASE = 84532;
    uint256 constant UNI = 1301;
    uint256 constant LIMIT = 10_000 ether;
    bytes32 constant CALLBACK_SIG = keccak256("CallbackRequested(uint256,address,uint64,bytes)");
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;

    ExitSentinel s;
    ExitSentinel.Market[2] mk;

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        for (uint256 i; i < 2; ++i) {
            uint160 o = uint160(0x1000 * (i + 1));
            mk[i] = ExitSentinel.Market({
                chainId: i == 0 ? BASE : UNI,
                pool: address(o + 1),
                asset: address(o + 2),
                adapter: address(o + 3),
                oracle: address(o + 4),
                hub: address(o + 5),
                weth: address(o + 6),
                hotWallet: address(o + 7)
            });
        }
        s = new ExitSentinel(mk, LIMIT);
    }

    // ---------- log builders ----------

    function _react(uint256 chainId, address c, string memory sig, uint256 topic1, bytes memory data) internal {
        IReactive.LogRecord memory l;
        l.chainId = chainId;
        l.contractAddress = c;
        l.topic0 = uint256(keccak256(bytes(sig)));
        l.topic1 = topic1;
        l.data = data;
        vm.prank(SYSTEM);
        s.react(l);
    }

    function _state(uint256 i, uint256 util, uint256 rate, uint256 avail, uint256 ts) internal {
        _react(mk[i].chainId, mk[i].pool, "ReserveState(address,uint256,uint256,uint256,uint256)", 0, abi.encode(util, rate, avail, ts));
    }

    function _borrowed(uint256 i, uint256 amt, uint256 ts) internal {
        _react(mk[i].chainId, mk[i].pool, "Borrowed(address,address,uint256,uint256)", 0, abi.encode(amt, ts));
    }

    function _frozen(uint256 i, uint256 ts) internal {
        _react(mk[i].chainId, mk[i].pool, "ReserveFrozen(address,uint256)", 0, abi.encode(ts));
    }

    function _adapter(uint256 i, uint256 bal, uint256 ts) internal {
        _react(mk[i].chainId, mk[i].adapter, "AdapterBalance(address,uint256,uint256)", 0, abi.encode(bal, ts));
    }

    function _hotTransfer(uint256 i, uint256 amt) internal {
        _react(mk[i].chainId, mk[i].weth, "Transfer(address,address,uint256)", uint160(mk[i].hotWallet), abi.encode(amt));
    }

    function _risk(uint256 i, uint8 level, uint256 ts) internal {
        _react(mk[i].chainId, mk[i].oracle, "RiskLevel(address,uint8,uint16,bytes32,uint256)", 0, abi.encode(level, uint16(0), bytes32(0), ts));
    }

    function _exitRound(uint256 i, uint256 originTs, uint256 paid) internal {
        _react(mk[i].chainId, mk[i].hub, "ExitRound(uint8,uint256,uint256,uint256)", 0, abi.encode(uint8(1), originTs, uint256(1), paid));
    }

    function _rearm(uint256 i) internal {
        _react(mk[i].chainId, mk[i].hub, "Rearm(address,uint256)", 0, abi.encode(uint256(0)));
    }

    // ---------- callback capture ----------

    struct Cb {
        uint256 chainId;
        address target;
        bytes payload;
    }

    function _callbacks() internal returns (Cb[] memory out) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) if (logs[i].topics[0] == CALLBACK_SIG) ++n;
        out = new Cb[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != CALLBACK_SIG) continue;
            out[n++] = Cb(uint256(logs[i].topics[1]), address(uint160(uint256(logs[i].topics[2]))), abi.decode(logs[i].data, (bytes)));
        }
    }

    function _assertTripBoth(uint8 reason, uint256 originTs) internal {
        Cb[] memory cbs = _callbacks();
        assertEq(cbs.length, 2, "callbacks");
        for (uint256 i; i < 2; ++i) {
            assertEq(cbs[i].chainId, mk[i].chainId);
            assertEq(cbs[i].target, mk[i].hub);
            assertEq(cbs[i].payload, abi.encodeWithSignature("exitAll(address,address,uint8,uint256)", address(0), mk[i].asset, reason, originTs));
        }
        assertTrue(s.exitMode());
    }

    function _assertNoCallbacks() internal {
        assertEq(_callbacks().length, 0, "unexpected callback");
    }

    // ---------- T1 borrow velocity ----------

    function test_T1_tripsAbove20PctOfWindowStartLiquidity() public {
        _state(0, 0, 0, 1000, 100);
        vm.recordLogs();
        _borrowed(0, 150, 101);
        _state(0, 1500, 75, 850, 101);
        _borrowed(0, 60, 200); // 210 > 200
        _assertTripBoth(1, 200);
    }

    function test_T1_windowResetsAfter10Min() public {
        _state(0, 0, 0, 1000, 100);
        _borrowed(0, 150, 100);
        _state(0, 1500, 75, 850, 100);
        vm.recordLogs();
        _borrowed(0, 150, 100 + 601); // new window, base 850
        _assertNoCallbacks();
    }

    function test_T6_hotWalletSwitchesT1ToHighRisk() public {
        _state(0, 0, 0, 1000, 100);
        _hotTransfer(1, LIMIT + 1); // outflow on the other chain still raises risk
        assertEq(s.highRiskUntil(), 2 hours); // Unichain has no ts yet, so 0 + 2h
        _hotTransfer(0, LIMIT + 1);
        assertEq(s.highRiskUntil(), 100 + 2 hours);
        vm.recordLogs();
        _borrowed(0, 110, 150); // 11% > 10%
        _assertTripBoth(1, 150);
    }

    function test_T6_smallTransferAndExpiryDoNothing() public {
        _state(0, 0, 0, 1000, 100);
        _hotTransfer(0, LIMIT);
        assertEq(s.highRiskUntil(), 0);
        _hotTransfer(0, LIMIT + 1);
        vm.recordLogs();
        _state(0, 0, 0, 1000, 100 + 2 hours); // expired
        _borrowed(0, 110, 100 + 2 hours);
        _assertNoCallbacks();
    }

    // ---------- T2 collateral drain ----------

    function test_T2_rsEthDrainTrips() public {
        _adapter(1, 116_723 ether, 100);
        vm.recordLogs();
        _adapter(1, 223 ether, 101);
        _assertTripBoth(2, 101);
    }

    function test_T2_40PctDropOnlyTripsAtHighRisk() public {
        _adapter(0, 100, 100);
        vm.recordLogs();
        _adapter(0, 60, 101);
        _assertNoCallbacks();
        _risk(0, 2, 102);
        _adapter(0, 36, 103);
        _assertTripBoth(2, 103);
    }

    // ---------- T3 / T4 ----------

    function test_T3_utilization() public {
        vm.recordLogs();
        _state(0, 8999, 0, 1, 100);
        _assertNoCallbacks();
        _state(0, 9000, 0, 1, 101);
        _assertTripBoth(3, 101);
    }

    function test_T4_rateNearCap() public {
        vm.recordLogs();
        _state(1, 0, 1189, 1, 100);
        _assertNoCallbacks();
        _state(1, 0, 1190, 1, 101); // 85% of 1400
        _assertTripBoth(4, 101);
    }

    // ---------- T5 / AI ----------

    function test_T5_freezeOnEitherChainExitsBoth() public {
        vm.recordLogs();
        _frozen(1, 500);
        _assertTripBoth(5, 500);
    }

    function test_AI_level2TightensLevel3Exits() public {
        _risk(0, 2, 100);
        vm.recordLogs();
        _state(0, 8000, 0, 1, 101);
        _assertTripBoth(3, 101);
    }

    function test_AI_level3ExitsAndLevel0Restores() public {
        _risk(0, 2, 100);
        _risk(0, 0, 101);
        vm.recordLogs();
        _state(0, 8000, 0, 1, 102);
        _assertNoCallbacks();
        _risk(0, 3, 103);
        _assertTripBoth(7, 103);
    }

    // ---------- exit mode ----------

    function test_oneIncidentOneExit() public {
        _frozen(0, 100);
        vm.recordLogs();
        _frozen(1, 101);
        _state(0, 10_000, 1400, 0, 102);
        _adapter(0, 100, 103);
        _adapter(0, 1, 104);
        _risk(0, 3, 105);
        _assertNoCallbacks();
        assertEq(s.exitReason(), 5);
    }

    function test_keepDrainingOnlyWhenLiquidityReturns() public {
        _state(0, 5000, 0, 500, 99);
        _frozen(0, 100);
        vm.recordLogs();
        _state(0, 10_000, 1400, 0, 101); // our own withdrawals: liquidity falls
        _assertNoCallbacks();
        _state(0, 9000, 1400, 40, 102); // repay: liquidity back
        Cb[] memory cbs = _callbacks();
        assertEq(cbs.length, 1);
        assertEq(cbs[0].chainId, BASE);
        assertEq(cbs[0].payload, abi.encodeWithSignature("exitAll(address,address,uint8,uint256)", address(0), mk[0].asset, uint8(5), uint256(102)));
    }

    function test_exitRoundContinuesWhilePaying() public {
        _frozen(0, 100);
        vm.recordLogs();
        _exitRound(1, 100, 5);
        Cb[] memory cbs = _callbacks();
        assertEq(cbs.length, 1);
        assertEq(cbs[0].chainId, UNI);
        _exitRound(1, 100, 0);
        _assertNoCallbacks();
    }

    function test_exitRoundIgnoredWhenArmed() public {
        vm.recordLogs();
        _exitRound(0, 100, 5);
        _assertNoCallbacks();
    }

    function test_rearmAllowsNextIncident() public {
        _frozen(0, 100);
        _rearm(0);
        assertFalse(s.exitMode());
        vm.recordLogs();
        _frozen(0, 200);
        _assertTripBoth(5, 200);
    }

    // ---------- deployment / wiring ----------

    function test_subscribesAndOnlySystemReacts() public {
        assertEq(MockSystem(SYSTEM).subs(), 16);
        IReactive.LogRecord memory l;
        vm.expectRevert();
        s.react(l);
    }

    /// The Sentinel's payload, with Reactive's rvmId substitution, is accepted by a real hub.
    function test_payloadDrivesRealHub() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        MockLendingPool pool = new MockLendingPool(usdc);
        address proxy = makeAddr("proxy");
        ShieldHub hub = new ShieldHub(proxy, pool);
        address alice = makeAddr("alice");
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        Shield sh = hub.createShield();
        usdc.approve(address(sh), 100e6);
        sh.deposit(100e6);
        vm.stopPrank();

        mk[0].asset = address(usdc);
        mk[0].hub = address(hub);
        s = new ExitSentinel(mk, LIMIT);
        hub.setSentinel(address(s));
        vm.recordLogs();
        _frozen(0, 100);
        bytes memory payload = _callbacks()[0].payload;
        address sentinel = address(s);
        assembly { mstore(add(payload, 36), sentinel) } // Reactive overwrites arg 0 with the requester's address

        vm.prank(proxy);
        (bool ok,) = address(hub).call(payload);
        assertTrue(ok);
        assertEq(usdc.balanceOf(alice), 100e6);
    }
}
