// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Single-asset Aave-style pool. Emits its full state after every action, because a
/// reactive contract can only see logs (and gets block numbers, not timestamps).
contract MockLendingPool is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant KINK_BPS = 8000;
    uint256 public constant SLOPE1_BPS = 400; // rate at the kink
    uint256 public constant SLOPE2_BPS = 6000;
    uint256 public constant CAP_BPS = 1400; // hard cap, mimics Kamino's 14%

    IERC20 public immutable asset;
    uint256 public totalSupplied;
    uint256 public totalBorrowed;
    bool public frozen;
    mapping(address => uint256) public supplied;
    mapping(address => uint256) public borrowed;

    event ReserveState(address indexed asset, uint256 utilizationBps, uint256 borrowRateBps, uint256 available, uint256 ts);
    event Borrowed(address indexed asset, address indexed borrower, uint256 amount, uint256 ts);
    event ReserveFrozen(address indexed asset, uint256 ts);

    error Frozen();
    error InsufficientLiquidity();

    constructor(IERC20 asset_) Ownable(msg.sender) {
        asset = asset_;
    }

    function available() public view returns (uint256) {
        return totalSupplied - totalBorrowed;
    }

    function utilizationBps() public view returns (uint256) {
        return totalSupplied == 0 ? 0 : (totalBorrowed * 10_000) / totalSupplied;
    }

    function borrowRateBps() public view returns (uint256) {
        uint256 u = utilizationBps();
        uint256 r = u <= KINK_BPS
            ? (u * SLOPE1_BPS) / KINK_BPS
            : SLOPE1_BPS + ((u - KINK_BPS) * SLOPE2_BPS) / (10_000 - KINK_BPS);
        return r > CAP_BPS ? CAP_BPS : r;
    }

    function supply(uint256 amount) external {
        if (frozen) revert Frozen();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        supplied[msg.sender] += amount;
        totalSupplied += amount;
        _emitState();
    }

    /// @dev Withdraw stays open when frozen (as on Aave); only liquidity limits it.
    function withdraw(uint256 amount) external {
        if (amount > available()) revert InsufficientLiquidity();
        supplied[msg.sender] -= amount;
        totalSupplied -= amount;
        asset.safeTransfer(msg.sender, amount);
        _emitState();
    }

    /// shortcut: no collateral or interest accrual, mock only so replays can drain the pool; v2 uses real Aave.
    function borrow(uint256 amount) external {
        if (frozen) revert Frozen();
        if (amount > available()) revert InsufficientLiquidity();
        borrowed[msg.sender] += amount;
        totalBorrowed += amount;
        asset.safeTransfer(msg.sender, amount);
        emit Borrowed(address(asset), msg.sender, amount, block.timestamp);
        _emitState();
    }

    function repay(uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        borrowed[msg.sender] -= amount;
        totalBorrowed -= amount;
        _emitState();
    }

    function freeze() external onlyOwner {
        frozen = true;
        emit ReserveFrozen(address(asset), block.timestamp);
    }

    function _emitState() internal {
        emit ReserveState(address(asset), utilizationBps(), borrowRateBps(), available(), block.timestamp);
    }
}
