// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockLendingPool} from "./MockLendingPool.sol";

/// @notice One per user. Supplies to the pool on the owner's behalf.
/// Every path that moves funds pays `owner`; there is no other recipient.
contract Shield is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable owner;
    address public immutable hub;
    MockLendingPool public immutable pool;
    IERC20 public immutable asset;

    event ExitExecuted(address indexed owner, address indexed asset, uint256 amount, uint8 reason, uint256 originTs, uint256 exitTs);

    error NotOwner();
    error NotHub();

    constructor(address owner_, MockLendingPool pool_) {
        owner = owner_;
        hub = msg.sender;
        pool = pool_;
        asset = pool_.asset();
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Pulls `amount` from the owner (needs approval to this Shield) and supplies it.
    function deposit(uint256 amount) external onlyOwner nonReentrant {
        asset.safeTransferFrom(owner, address(this), amount);
        asset.forceApprove(address(pool), amount);
        pool.supply(amount);
    }

    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        pool.withdraw(amount);
        asset.safeTransfer(owner, amount);
    }

    function supplied() external view returns (uint256) {
        return pool.supplied(address(this));
    }

    /// @notice Withdraws as much as the pool can pay right now and sends it to the owner.
    function emergencyExit(uint8 reason, uint256 originTs) external nonReentrant returns (uint256 amount) {
        if (msg.sender != hub) revert NotHub();
        uint256 bal = pool.supplied(address(this));
        uint256 avail = pool.available();
        amount = bal < avail ? bal : avail;
        if (amount == 0) return 0;
        pool.withdraw(amount);
        asset.safeTransfer(owner, amount);
        emit ExitExecuted(owner, address(asset), amount, reason, originTs, block.timestamp);
    }
}
