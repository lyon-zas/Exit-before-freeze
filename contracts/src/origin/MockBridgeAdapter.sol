// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Holds the bridged collateral (rsETH stand-in). Emits its balance after every move so a
/// one-block collapse is visible to the Sentinel.
contract MockBridgeAdapter is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    event AdapterBalance(address indexed token, uint256 balance, uint256 ts);

    constructor(IERC20 token_) Ownable(msg.sender) {
        token = token_;
    }

    /// @notice Emits the current balance (call after seeding so the Sentinel has a baseline).
    function sync() external {
        _emitBalance();
    }

    function release(address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
        _emitBalance();
    }

    function _emitBalance() internal {
        emit AdapterBalance(address(token), token.balanceOf(address(this)), block.timestamp);
    }
}
