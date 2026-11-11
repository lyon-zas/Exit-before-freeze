// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../src/origin/MockERC20.sol";
import {ShieldHub} from "../src/origin/ShieldHub.sol";
import {Shield} from "../src/origin/Shield.sol";

/// Creates the sender's Shield on this chain (if missing) and deposits AMOUNT mock USDC into it.
///
///   forge script script/SeedShield.s.sol --rpc-url https://sepolia.base.org --account deployer --broadcast
///
/// Env (optional): AMOUNT in USDC units (default 1000e6 = 1,000 mUSDC).
contract SeedShield is Script {
    function run() external {
        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".json"));
        ShieldHub hub = ShieldHub(payable(vm.parseJsonAddress(j, ".hub")));
        MockERC20 usdc = MockERC20(vm.parseJsonAddress(j, ".usdc"));
        uint256 amount = vm.envOr("AMOUNT", uint256(1000e6));

        vm.startBroadcast();
        Shield s = hub.shieldOf(msg.sender);
        if (address(s) == address(0)) s = hub.createShield();
        usdc.mint(msg.sender, amount);
        usdc.approve(address(s), amount);
        s.deposit(amount);
        vm.stopBroadcast();

        console.log("shield", address(s));
        console.log("supplied", s.supplied());
    }
}
