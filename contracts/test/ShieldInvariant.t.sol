// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/origin/MockERC20.sol";
import {MockLendingPool} from "../src/origin/MockLendingPool.sol";
import {ShieldHub} from "../src/origin/ShieldHub.sol";
import {Shield} from "../src/origin/Shield.sol";

/// @dev Random deposits, withdrawals, borrows, repays and exits.
contract Handler is Test {
    MockERC20 public usdc;
    MockLendingPool public pool;
    ShieldHub public hub;
    address public proxy;
    address public rvmId;
    address public borrower = makeAddr("borrower");
    address[3] public owners;
    uint256 public constant MINT = 1_000e6;

    constructor(MockERC20 usdc_, MockLendingPool pool_, ShieldHub hub_, address proxy_, address rvmId_) {
        (usdc, pool, hub, proxy, rvmId) = (usdc_, pool_, hub_, proxy_, rvmId_);
        for (uint256 i; i < 3; ++i) {
            owners[i] = makeAddr(string(abi.encode("owner", i)));
            usdc.mint(owners[i], MINT);
            vm.startPrank(owners[i]);
            Shield s = hub.createShield();
            usdc.approve(address(s), type(uint256).max);
            vm.stopPrank();
        }
        usdc.mint(borrower, 10_000e6);
        vm.prank(borrower);
        usdc.approve(address(pool), type(uint256).max);
    }

    function deposit(uint256 who, uint256 amt) external {
        address o = owners[who % 3];
        amt = bound(amt, 0, usdc.balanceOf(o));
        Shield s = hub.shieldOf(o);
        vm.prank(o);
        s.deposit(amt);
    }

    function withdraw(uint256 who, uint256 amt) external {
        address o = owners[who % 3];
        Shield s = hub.shieldOf(o);
        uint256 max = s.supplied() < pool.available() ? s.supplied() : pool.available();
        amt = bound(amt, 0, max);
        vm.prank(o);
        s.withdraw(amt);
    }

    function borrow(uint256 amt) external {
        amt = bound(amt, 0, pool.available());
        vm.prank(borrower);
        pool.borrow(amt);
    }

    function repay(uint256 amt) external {
        amt = bound(amt, 0, pool.borrowed(borrower));
        vm.prank(borrower);
        pool.repay(amt);
    }

    function exitAll(uint8 reason) external {
        vm.prank(proxy);
        hub.exitAll(rvmId, address(usdc), reason, block.timestamp);
    }
}

contract ShieldInvariantTest is Test {
    Handler h;

    function setUp() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockLendingPool pool = new MockLendingPool(usdc);
        address proxy = makeAddr("callbackProxy");
        ShieldHub hub = new ShieldHub(proxy, pool);
        hub.setSentinel(address(this));
        h = new Handler(usdc, pool, hub, proxy, address(this));
        targetContract(address(h));
    }

    /// Each owner's wallet + supplied position is constant: funds only ever move between the
    /// owner and their own pool position, never to anyone else.
    function invariant_fundsOnlyReachOwner() public view {
        for (uint256 i; i < 3; ++i) {
            address o = h.owners(i);
            Shield s = h.hub().shieldOf(o);
            assertEq(h.usdc().balanceOf(o) + s.supplied(), h.MINT());
            assertEq(h.usdc().balanceOf(address(s)), 0);
        }
        assertEq(h.usdc().balanceOf(address(h.hub())), 0);
    }
}
