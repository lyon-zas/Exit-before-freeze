// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/origin/MockERC20.sol";
import {MockLendingPool} from "../src/origin/MockLendingPool.sol";
import {MockBridgeAdapter} from "../src/origin/MockBridgeAdapter.sol";
import {RiskOracle} from "../src/origin/RiskOracle.sol";

contract PoolTest is Test {
    event ReserveState(address indexed asset, uint256 utilizationBps, uint256 borrowRateBps, uint256 available, uint256 ts);
    event ReserveFrozen(address indexed asset, uint256 ts);

    MockERC20 usdc;
    MockLendingPool pool;
    address borrower = makeAddr("borrower");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockLendingPool(usdc);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.supply(1_000e6);
    }

    function _borrow(uint256 amt) internal {
        vm.prank(borrower);
        pool.borrow(amt);
    }

    function test_rateCurveKinkAndCap() public {
        _borrow(400e6); // 40% -> half of slope1
        assertEq(pool.utilizationBps(), 4000);
        assertEq(pool.borrowRateBps(), 200);
        _borrow(400e6); // 80% -> at kink
        assertEq(pool.borrowRateBps(), 400);
        _borrow(100e6); // 90% -> 400 + 3000 = 3400, capped
        assertEq(pool.borrowRateBps(), 1400);
    }

    function test_emitsStateWithTimestamp() public {
        vm.warp(1_000_000);
        vm.expectEmit(address(pool));
        emit ReserveState(address(usdc), 1000, 50, 900e6, 1_000_000);
        _borrow(100e6);
    }

    function test_cannotBorrowOrWithdrawBeyondAvailable() public {
        _borrow(1_000e6);
        assertEq(pool.available(), 0);
        vm.expectRevert(MockLendingPool.InsufficientLiquidity.selector);
        pool.withdraw(1);
    }

    function test_freezeBlocksSupplyAndBorrowNotWithdraw() public {
        vm.expectEmit(address(pool));
        emit ReserveFrozen(address(usdc), block.timestamp);
        pool.freeze();
        vm.expectRevert(MockLendingPool.Frozen.selector);
        _borrow(1);
        vm.expectRevert(MockLendingPool.Frozen.selector);
        pool.supply(1);
        pool.withdraw(10e6);
        assertEq(usdc.balanceOf(address(this)), 10e6);
    }

    function test_onlyOwnerFreezes() public {
        vm.prank(borrower);
        vm.expectRevert();
        pool.freeze();
    }

    function test_repayRestoresLiquidity() public {
        _borrow(1_000e6);
        vm.startPrank(borrower);
        usdc.approve(address(pool), 300e6);
        pool.repay(300e6);
        vm.stopPrank();
        assertEq(pool.available(), 300e6);
    }

    function test_adapterAndOracleGuards() public {
        MockERC20 rseth = new MockERC20("rsETH", "rsETH", 18);
        MockBridgeAdapter adapter = new MockBridgeAdapter(rseth);
        rseth.mint(address(adapter), 100 ether);
        vm.prank(borrower);
        vm.expectRevert();
        adapter.release(borrower, 1);
        adapter.release(borrower, 99 ether);
        assertEq(rseth.balanceOf(address(adapter)), 1 ether);

        RiskOracle oracle = new RiskOracle(address(this));
        oracle.post(address(pool), 2, 700, bytes32(0));
        vm.expectRevert(RiskOracle.BadLevel.selector);
        oracle.post(address(pool), 4, 700, bytes32(0));
        vm.prank(borrower);
        vm.expectRevert(RiskOracle.NotAgent.selector);
        oracle.post(address(pool), 3, 999, bytes32(0));
    }
}
