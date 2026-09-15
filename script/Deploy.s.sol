// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";

/// @notice Deploys MilestoneEscrow. No constructor arguments, no post-deploy configuration.
/// @dev Usage (keystore, never a raw key in .env):
///      forge script script/Deploy.s.sol --rpc-url base_sepolia --account deployer --broadcast --verify
contract Deploy is Script {
    function run() external returns (MilestoneEscrow escrow) {
        vm.startBroadcast();
        escrow = new MilestoneEscrow();
        vm.stopBroadcast();

        console.log("MilestoneEscrow deployed at:", address(escrow));
        console.log("chain id:", block.chainid);
    }
}
