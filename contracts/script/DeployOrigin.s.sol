// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../src/origin/MockERC20.sol";
import {MockLendingPool} from "../src/origin/MockLendingPool.sol";
import {MockBridgeAdapter} from "../src/origin/MockBridgeAdapter.sol";
import {RiskOracle} from "../src/origin/RiskOracle.sol";
import {ShieldHub} from "../src/origin/ShieldHub.sol";

/// Deploys the origin-side contracts on Base Sepolia or Unichain Sepolia and writes
/// ../deployments/<chainId>.json. The deployer becomes hub admin (sets the Sentinel, re-arms).
///
///   forge script script/DeployOrigin.s.sol --rpc-url $BASE_SEPOLIA_RPC --account deployer --broadcast
///
/// Env (optional): AGENT (RiskOracle signer, default deployer), HOT_WALLET (default deployer),
/// HUB_FUNDING (wei deposited for the hub at the callback proxy, default 0.001 ether).
/// Top up later: cast send $PROXY "depositTo(address)" $HUB --value 0.01ether --rpc-url ... --account deployer
contract DeployOrigin is Script {
    function callbackProxy() internal view returns (address) {
        if (block.chainid == 84532) return 0x476F44b11F5C942c58f4c8E3d0300E5710743585; // Base Sepolia
        if (block.chainid == 1301) return 0x775c9B990ADe401060B78D0e98684eEf8d2466C1; // Unichain Sepolia
        revert("unsupported chain");
    }

    function _path() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".json");
    }

    /// Callback reserves must go through the proxy; a plain transfer to the hub is not counted.
    function _fundHub(address proxy, address hub, uint256 amount) internal {
        (bool ok,) = proxy.call{value: amount}(abi.encodeWithSignature("depositTo(address)", hub));
        require(ok, "depositTo failed");
    }

    function run() external {
        address proxy = callbackProxy();
        // a rerun from shell history silently replaces the set the Sentinel watches
        require(!vm.exists(_path()) || vm.envOr("FORCE", false), "already deployed on this chain; set FORCE=true to redeploy");
        vm.startBroadcast();
        address deployer = msg.sender;
        address agent = vm.envOr("AGENT", deployer);
        address hotWallet = vm.envOr("HOT_WALLET", deployer);
        uint256 hubFunding = vm.envOr("HUB_FUNDING", uint256(0.001 ether));

        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        MockERC20 weth = new MockERC20("Mock WETH", "mWETH", 18);
        MockERC20 rseth = new MockERC20("Mock rsETH", "mrsETH", 18);
        MockLendingPool pool = new MockLendingPool(usdc);
        MockBridgeAdapter adapter = new MockBridgeAdapter(rseth);
        RiskOracle oracle = new RiskOracle(agent);
        ShieldHub hub = new ShieldHub(proxy, pool);
        _fundHub(proxy, address(hub), hubFunding);

        rseth.mint(address(adapter), 116_723 ether); // rsETH-adapter-sized baseline
        adapter.sync();
        weth.mint(hotWallet, 200_000 ether);
        vm.stopBroadcast();

        string memory k = "d";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "admin", deployer);
        vm.serializeAddress(k, "callbackProxy", proxy);
        vm.serializeAddress(k, "usdc", address(usdc));
        vm.serializeAddress(k, "weth", address(weth));
        vm.serializeAddress(k, "rseth", address(rseth));
        vm.serializeAddress(k, "pool", address(pool));
        vm.serializeAddress(k, "adapter", address(adapter));
        vm.serializeAddress(k, "oracle", address(oracle));
        vm.serializeAddress(k, "hotWallet", hotWallet);
        string memory json = vm.serializeAddress(k, "hub", address(hub));
        vm.writeJson(json, _path());
        console.log("wrote", _path());
    }
}
