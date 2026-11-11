// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @notice Watches one lending market per origin chain (plus its bridge adapter, risk oracle and a
/// hot wallet) and, when a trigger trips, calls ShieldHub.exitAll on BOTH chains.
/// Runs on Reactive Lasna; the system contract calls react() for each subscribed log, so every
/// input (including re-arm and AI risk level) arrives as an event.
contract ExitSentinel is AbstractReactive {
    struct Market {
        uint256 chainId;
        address pool;
        address asset; // pool asset
        address adapter;
        address oracle;
        address hub;
        address weth;
        address hotWallet;
    }

    struct Thresholds {
        uint16 borrowVelBps; // T1: borrowed in window vs liquidity at window start
        uint16 drainBps; // T2: adapter balance drop between two events
        uint16 utilBps; // T3
        uint16 rateOfCapBps; // T4: rate vs pool cap
    }

    // reason codes, carried to ExitExecuted
    uint8 public constant R_BORROW_VELOCITY = 1;
    uint8 public constant R_COLLATERAL_DRAIN = 2;
    uint8 public constant R_UTILIZATION = 3;
    uint8 public constant R_RATE = 4;
    uint8 public constant R_FREEZE = 5;
    uint8 public constant R_AI_CRITICAL = 7;

    uint64 public constant GAS_LIMIT = 2_000_000; // ~1.73M measured for a 20-Shield batch
    uint256 public constant WINDOW = 10 minutes;
    uint256 public constant HIGH_RISK_FOR = 2 hours;
    uint256 public constant RATE_CAP_BPS = 1400; // MockLendingPool.CAP_BPS

    uint256 constant RESERVE_STATE = uint256(keccak256("ReserveState(address,uint256,uint256,uint256,uint256)"));
    uint256 constant BORROWED = uint256(keccak256("Borrowed(address,address,uint256,uint256)"));
    uint256 constant RESERVE_FROZEN = uint256(keccak256("ReserveFrozen(address,uint256)"));
    uint256 constant ADAPTER_BALANCE = uint256(keccak256("AdapterBalance(address,uint256,uint256)"));
    uint256 constant TRANSFER = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 constant RISK_LEVEL = uint256(keccak256("RiskLevel(address,uint8,uint16,bytes32,uint256)"));
    uint256 constant REARM = uint256(keccak256("Rearm(address,uint256)"));
    uint256 constant EXIT_ROUND = uint256(keccak256("ExitRound(uint8,uint256,uint256,uint256)"));

    Market[2] public markets;
    uint256 public immutable hotWalletLimit; // T6: single transfer size that switches to high risk

    // --- trigger state ---
    bool public exitMode;
    uint8 public exitReason;
    uint256 public highRiskUntil; // T6
    mapping(uint256 => uint256) public lastTs; // chainId => latest event ts seen
    mapping(uint256 => uint256) public lastAvailable;
    mapping(uint256 => uint256) public winStart;
    mapping(uint256 => uint256) public winBase;
    mapping(uint256 => uint256) public winBorrowed;
    mapping(uint256 => uint256) public lastAdapterBal;
    mapping(uint256 => bool) public aiHigh;

    event Tripped(uint256 indexed chainId, uint8 reason, uint256 originTs);
    event HighRisk(uint256 until);

    constructor(Market[2] memory markets_, uint256 hotWalletLimit_) payable {
        hotWalletLimit = hotWalletLimit_;
        for (uint256 i; i < 2; ++i) markets[i] = markets_[i];
        for (uint256 i; i < 2; ++i) {
            Market memory m = markets_[i];
            _sub(m.chainId, m.pool, RESERVE_STATE, REACTIVE_IGNORE);
            _sub(m.chainId, m.pool, BORROWED, REACTIVE_IGNORE);
            _sub(m.chainId, m.pool, RESERVE_FROZEN, REACTIVE_IGNORE);
            _sub(m.chainId, m.adapter, ADAPTER_BALANCE, REACTIVE_IGNORE);
            _sub(m.chainId, m.oracle, RISK_LEVEL, REACTIVE_IGNORE);
            _sub(m.chainId, m.hub, REARM, REACTIVE_IGNORE);
            _sub(m.chainId, m.hub, EXIT_ROUND, REACTIVE_IGNORE);
            _sub(m.chainId, m.weth, TRANSFER, uint256(uint160(m.hotWallet)));
        }
    }

    function _sub(uint256 chainId, address c, uint256 topic0, uint256 topic1) internal {
        SYSTEM.subscribe(chainId, c, topic0, topic1, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function thresholds(uint256 chainId, uint256 ts) public view returns (Thresholds memory) {
        if (aiHigh[chainId] || ts < highRiskUntil) return Thresholds(1000, 3000, 8000, 8500);
        return Thresholds(2000, 5000, 9000, 8500);
    }

    function react(LogRecord calldata log) external onlySystem {
        uint256 c = log.chainId;
        uint256 t0 = log.topic0;

        if (t0 == RESERVE_STATE) {
            (uint256 util, uint256 rate, uint256 avail, uint256 ts) = abi.decode(log.data, (uint256, uint256, uint256, uint256));
            uint256 prevAvail = lastAvailable[c];
            lastTs[c] = ts;
            lastAvailable[c] = avail;
            if (exitMode) {
                // keep draining, but only when liquidity came back (repay/supply), never on our own withdrawals
                if (avail > prevAvail) _callback(c, exitReason, ts);
                return;
            }
            Thresholds memory th = thresholds(c, ts);
            if (util >= th.utilBps) return _trip(c, R_UTILIZATION, ts);
            // "rate doubles within 1h" is left out: it false-trips at low rates, and on this curve
            // the cap check already fires first (85% of cap is ~83% utilization).
            if (rate * 10_000 >= RATE_CAP_BPS * th.rateOfCapBps) return _trip(c, R_RATE, ts);
        } else if (t0 == BORROWED) {
            (uint256 amount, uint256 ts) = abi.decode(log.data, (uint256, uint256));
            lastTs[c] = ts;
            if (winStart[c] == 0 || ts - winStart[c] > WINDOW) {
                // Borrowed is emitted before the pool's ReserveState, so lastAvailable is pre-borrow liquidity
                (winStart[c], winBase[c], winBorrowed[c]) = (ts, lastAvailable[c], 0);
            }
            winBorrowed[c] += amount;
            if (!exitMode && winBase[c] > 0 && winBorrowed[c] * 10_000 > winBase[c] * thresholds(c, ts).borrowVelBps) {
                _trip(c, R_BORROW_VELOCITY, ts);
            }
        } else if (t0 == RESERVE_FROZEN) {
            uint256 ts = abi.decode(log.data, (uint256));
            lastTs[c] = ts;
            if (!exitMode) _trip(c, R_FREEZE, ts);
        } else if (t0 == ADAPTER_BALANCE) {
            (uint256 bal, uint256 ts) = abi.decode(log.data, (uint256, uint256));
            lastTs[c] = ts;
            uint256 prev = lastAdapterBal[c];
            lastAdapterBal[c] = bal;
            if (!exitMode && prev > 0 && bal * 10_000 < prev * (10_000 - thresholds(c, ts).drainBps)) {
                _trip(c, R_COLLATERAL_DRAIN, ts);
            }
        } else if (t0 == TRANSFER) {
            // shortcut: ERC-20 Transfer has no ts, so use the latest ts seen on that chain; fine while the pool is active.
            if (abi.decode(log.data, (uint256)) > hotWalletLimit) {
                highRiskUntil = lastTs[c] + HIGH_RISK_FOR;
                emit HighRisk(highRiskUntil);
            }
        } else if (t0 == RISK_LEVEL) {
            (uint8 level,,, uint256 ts) = abi.decode(log.data, (uint8, uint16, bytes32, uint256));
            lastTs[c] = ts;
            aiHigh[c] = level >= 2;
            if (level == 3 && !exitMode) _trip(c, R_AI_CRITICAL, ts);
        } else if (t0 == EXIT_ROUND) {
            (, uint256 originTs,, uint256 paid) = abi.decode(log.data, (uint8, uint256, uint256, uint256));
            // another round while the last one paid out: picks up Shields past the batch cap
            if (exitMode && paid > 0) _callback(c, exitReason, originTs);
        } else if (t0 == REARM) {
            exitMode = false;
            exitReason = 0;
            for (uint256 i; i < 2; ++i) winStart[markets[i].chainId] = 0;
        }
    }

    function _trip(uint256 chainId, uint8 reason, uint256 originTs) internal {
        exitMode = true;
        exitReason = reason;
        emit Tripped(chainId, reason, originTs);
        for (uint256 i; i < 2; ++i) _callback(markets[i].chainId, reason, originTs);
    }

    function _callback(uint256 chainId, uint8 reason, uint256 originTs) internal {
        Market storage m = markets[chainId == markets[0].chainId ? 0 : 1];
        bytes memory payload = abi.encodeWithSignature(
            "exitAll(address,address,uint8,uint256)", address(0), m.asset, reason, originTs
        );
        SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0(m.chainId, m.hub, GAS_LIMIT, payload));
    }
}
