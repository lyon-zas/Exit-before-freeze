// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {ExitSentinel} from "../src/reactive/ExitSentinel.sol";

/// Deploys ExitSentinel on Reactive Lasna, wired to both origin deployments.
/// Run DeployOrigin on both chains first. Afterwards, wire each hub with the printed setSentinel commands.
///
///   forge script script/DeploySentinel.s.sol --rpc-url https://lasna-rpc.rnk.dev --account deployer --broadcast
///
/// Env (optional): SENTINEL_FUNDING (REACT wei deposited to the Sentinel's reserves, default 1 ether),
/// HOT_WALLET_LIMIT (T6 transfer size, default 10_000 ether).
contract DeploySentinel is Script {
    function _market(uint256 chainId) internal view returns (ExitSentinel.Market memory m) {
        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/../deployments/", vm.toString(chainId), ".json"));
        m = ExitSentinel.Market({
            chainId: chainId,
            pool: vm.parseJsonAddress(j, ".pool"),
            asset: vm.parseJsonAddress(j, ".usdc"),
            adapter: vm.parseJsonAddress(j, ".adapter"),
            oracle: vm.parseJsonAddress(j, ".oracle"),
            hub: vm.parseJsonAddress(j, ".hub"),
            weth: vm.parseJsonAddress(j, ".weth"),
            hotWallet: vm.parseJsonAddress(j, ".hotWallet")
        });
    }

    /// Fees are paid from reserves at the system contract (0x8888..., reactive-lib-omni's SYSTEM).
    function _fund(address sentinel, uint256 amount) internal {
        (bool ok,) = address(0x8888888888888888888888888888888888888888).call{value: amount}(abi.encodeWithSignature("depositTo(address)", sentinel));
        require(ok, "depositTo failed");
    }

    function run() external {
        require(block.chainid == 5318007, "deploy on Reactive Lasna");
        require(
            !vm.exists(string.concat(vm.projectRoot(), "/../deployments/5318007.json")) || vm.envOr("FORCE", false),
            "Sentinel already deployed; set FORCE=true to redeploy"
        );
        ExitSentinel.Market[2] memory mk;
        mk[0] = _market(84532);
        mk[1] = _market(1301);
        uint256 funding = vm.envOr("SENTINEL_FUNDING", uint256(1 ether));
        uint256 limit = vm.envOr("HOT_WALLET_LIMIT", uint256(10_000 ether));

        vm.startBroadcast();
        ExitSentinel s = new ExitSentinel(mk, limit);
        _fund(address(s), funding);
        vm.stopBroadcast();

        string memory json = vm.serializeAddress("s", "sentinel", address(s));
        vm.writeJson(json, string.concat(vm.projectRoot(), "/../deployments/5318007.json"));
        console.log("ExitSentinel", address(s));
        console.log("Now wire both hubs (from the hub deployer):");
        console.log(string.concat("  cast send ", vm.toString(mk[0].hub), " 'setSentinel(address)' ", vm.toString(address(s)), " --rpc-url https://sepolia.base.org --account deployer"));
        console.log(string.concat("  cast send ", vm.toString(mk[1].hub), " 'setSentinel(address)' ", vm.toString(address(s)), " --rpc-url https://sepolia.unichain.org --account deployer"));
    }
}
