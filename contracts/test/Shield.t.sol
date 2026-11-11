// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/origin/MockERC20.sol";
import {MockLendingPool} from "../src/origin/MockLendingPool.sol";
import {ShieldHub} from "../src/origin/ShieldHub.sol";
import {Shield} from "../src/origin/Shield.sol";

contract ShieldTest is Test {
    MockERC20 usdc;
    MockLendingPool pool;
    ShieldHub hub; // sentinel set to address(this), so this test plays the Sentinel
    address proxy = makeAddr("callbackProxy");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address borrower = makeAddr("borrower");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockLendingPool(usdc);
        hub = new ShieldHub(proxy, pool);
        hub.setSentinel(address(this));
    }

    function _shieldAndDeposit(address user, uint256 amt) internal returns (Shield s) {
        usdc.mint(user, amt);
        vm.startPrank(user);
        s = hub.createShield();
        usdc.approve(address(s), amt);
        s.deposit(amt);
        vm.stopPrank();
    }

    function _borrow(uint256 amt) internal {
        vm.prank(borrower);
        pool.borrow(amt);
    }

    function _exit() internal {
        vm.prank(proxy);
        hub.exitAll(address(this), address(usdc), 5, 123);
    }

    function test_exitPaysOwners() public {
        _shieldAndDeposit(alice, 100e6);
        _shieldAndDeposit(bob, 50e6);
        _exit();
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(usdc.balanceOf(bob), 50e6);
        assertEq(pool.totalSupplied(), 0);
    }

    function test_exitEmitsBothTimestamps() public {
        Shield s = _shieldAndDeposit(alice, 100e6);
        vm.warp(130);
        vm.expectEmit(address(s));
        emit Shield.ExitExecuted(alice, address(usdc), 100e6, 5, 123, 130);
        _exit();
    }

    function test_partialExitThenKeepDraining() public {
        Shield s = _shieldAndDeposit(alice, 100e6);
        _borrow(70e6);
        _exit();
        assertEq(usdc.balanceOf(alice), 30e6);
        assertEq(s.supplied(), 70e6);

        vm.startPrank(borrower);
        usdc.approve(address(pool), 70e6);
        pool.repay(70e6);
        vm.stopPrank();
        _exit();
        assertEq(usdc.balanceOf(alice), 100e6);
    }

    function test_exitBatchesAndCursorWraps() public {
        for (uint256 i; i < 25; ++i) _shieldAndDeposit(address(uint160(0x1000 + i)), 1e6);
        _exit();
        assertEq(pool.totalSupplied(), 5e6);
        assertEq(hub.cursor(), 20);
        _exit();
        assertEq(pool.totalSupplied(), 0);
        for (uint256 i; i < 25; ++i) assertEq(usdc.balanceOf(address(uint160(0x1000 + i))), 1e6);
    }

    function test_exitWithNoShieldsIsNoop() public {
        _exit();
        assertEq(hub.cursor(), 0);
    }

    function test_hubRejectsNonProxy() public {
        _shieldAndDeposit(alice, 100e6);
        vm.expectRevert(ShieldHub.NotCallbackProxy.selector);
        hub.exitAll(address(this), address(usdc), 5, 123);
    }

    function test_hubRejectsWrongRvmId(address rvmId) public {
        vm.assume(rvmId != address(this));
        vm.prank(proxy);
        vm.expectRevert(ShieldHub.NotSentinel.selector);
        hub.exitAll(rvmId, address(usdc), 5, 123);
    }

    function test_hubRejectsWrongAsset() public {
        vm.prank(proxy);
        vm.expectRevert(ShieldHub.WrongAsset.selector);
        hub.exitAll(address(this), address(0xBEEF), 5, 123);
    }

    function test_oneShieldPerUser() public {
        vm.startPrank(alice);
        hub.createShield();
        vm.expectRevert(ShieldHub.AlreadyHasShield.selector);
        hub.createShield();
    }

    function test_sentinelSetOnceByAdmin() public {
        vm.expectRevert(ShieldHub.SentinelAlreadySet.selector);
        hub.setSentinel(alice);
        ShieldHub fresh = new ShieldHub(proxy, pool);
        vm.prank(alice);
        vm.expectRevert(ShieldHub.NotAdmin.selector);
        fresh.setSentinel(alice);
        vm.prank(proxy); // unset sentinel rejects even a zero rvmId
        vm.expectRevert(ShieldHub.NotSentinel.selector);
        fresh.exitAll(address(0), address(usdc), 5, 123);
    }

    function test_onlyAdminRearms() public {
        hub.rearm();
        vm.prank(alice);
        vm.expectRevert(ShieldHub.NotAdmin.selector);
        hub.rearm();
    }

    function testFuzz_strangersCannotMoveFunds(address stranger) public {
        Shield s = _shieldAndDeposit(alice, 100e6);
        vm.assume(stranger != alice && stranger != address(hub));
        vm.startPrank(stranger);
        vm.expectRevert(Shield.NotOwner.selector);
        s.withdraw(1);
        vm.expectRevert(Shield.NotOwner.selector);
        s.deposit(1);
        vm.expectRevert(Shield.NotHub.selector);
        s.emergencyExit(1, 0);
        vm.stopPrank();
    }

    function testFuzz_exitPaysMinOfBalanceAndAvailable(uint96 dep, uint96 other, uint96 borrowAmt) public {
        dep = uint96(bound(dep, 1, 1e15));
        other = uint96(bound(other, 0, 1e15));
        Shield s = _shieldAndDeposit(alice, dep);
        if (other > 0) _shieldAndDeposit(bob, other);
        uint256 b = bound(borrowAmt, 0, uint256(dep) + other);
        if (b > 0) _borrow(b);

        uint256 avail = pool.available();
        uint256 expected = dep < avail ? dep : avail;
        vm.prank(address(hub));
        uint256 paid = s.emergencyExit(1, 0);
        assertEq(paid, expected);
        assertEq(usdc.balanceOf(alice), expected);
        assertEq(usdc.balanceOf(address(s)), 0);
    }
}
