// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice The only contract the AI agent can write to. Holds no funds, moves no funds.
contract RiskOracle {
    address public immutable agent;

    event RiskLevel(address indexed market, uint8 level, uint16 score, bytes32 reasonHash, uint256 ts);

    error NotAgent();
    error BadLevel();

    constructor(address agent_) {
        agent = agent_;
    }

    function post(address market, uint8 level, uint16 score, bytes32 reasonHash) external {
        if (msg.sender != agent) revert NotAgent();
        if (level > 3) revert BadLevel();
        emit RiskLevel(market, level, score, reasonHash, block.timestamp);
    }
}
