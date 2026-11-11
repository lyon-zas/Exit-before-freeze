// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractPayer} from "reactive-lib/base/AbstractPayer.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {MockLendingPool} from "./MockLendingPool.sol";
import {Shield} from "./Shield.sol";

/// @notice One per chain. Creates Shields and is the Reactive callback target.
/// `exitAll` only runs when called by the chain's callback proxy AND Reactive has stamped the
/// Sentinel's address into the first argument.
/// Not using the lib's AbstractCallback: its sender is immutable, but the Sentinel (on Lasna) can
/// only be deployed after the hubs exist, so the admin sets it once instead.
contract ShieldHub is AbstractPayer {
    uint256 public constant MAX_BATCH = 20;

    MockLendingPool public immutable pool;
    address public immutable asset;
    address public immutable admin;
    address public immutable callbackProxy;
    address public sentinel;

    Shield[] public shields;
    mapping(address => Shield) public shieldOf;
    uint256 public cursor; // next shield to process; lets later rounds pick up the rest

    event ShieldCreated(address indexed owner, address shield);
    event ExitRound(uint8 reason, uint256 originTs, uint256 processed, uint256 totalPaid);
    event Rearm(address indexed asset, uint256 ts);

    error AlreadyHasShield();
    error WrongAsset();
    error NotAdmin();
    error SentinelAlreadySet();
    error NotCallbackProxy();
    error NotSentinel();

    constructor(address callbackProxy_, MockLendingPool pool_) payable AbstractPayer(IPayable(payable(callbackProxy_))) {
        pool = pool_;
        asset = address(pool_.asset());
        admin = msg.sender;
        callbackProxy = callbackProxy_;
    }

    /// @notice One-time wiring to the ExitSentinel on Reactive.
    function setSentinel(address sentinel_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (sentinel != address(0)) revert SentinelAlreadySet();
        sentinel = sentinel_;
    }

    function createShield() external returns (Shield s) {
        if (address(shieldOf[msg.sender]) != address(0)) revert AlreadyHasShield();
        s = new Shield(msg.sender, pool);
        shieldOf[msg.sender] = s;
        shields.push(s);
        emit ShieldCreated(msg.sender, address(s));
    }

    function shieldCount() external view returns (uint256) {
        return shields.length;
    }

    /// @notice Reactive callback. Reactive overwrites `rvmId` with the requesting contract's address.
    function exitAll(address rvmId, address asset_, uint8 reason, uint256 originTs) external {
        if (msg.sender != callbackProxy) revert NotCallbackProxy();
        if (rvmId != sentinel || rvmId == address(0)) revert NotSentinel();
        if (asset_ != asset) revert WrongAsset();
        uint256 n = shields.length;
        uint256 count = n < MAX_BATCH ? n : MAX_BATCH;
        uint256 c = cursor;
        uint256 paid;
        for (uint256 i; i < count; ++i) {
            paid += shields[c].emergencyExit(reason, originTs);
            c = c + 1 == n ? 0 : c + 1;
        }
        cursor = c;
        emit ExitRound(reason, originTs, count, paid);
    }

    /// @notice Ends exit mode in the Sentinel (it subscribes to this event).
    function rearm() external {
        if (msg.sender != admin) revert NotAdmin();
        emit Rearm(asset, block.timestamp);
    }
}
