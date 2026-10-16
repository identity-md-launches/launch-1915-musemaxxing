// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {MuseMaxxingToken} from "../src/MuseMaxxingToken.sol";

/// @title DeployMuseMaxxing
/// @notice Local and testnet deployment helper. The token takes no configuration, so there is
/// nothing to read from the environment: `deploy()` is the whole deployment and tests call it
/// directly. On the IdentityMD launch the ProjectFactory deploys the token from its creation code
/// itself; this script is not part of that flow and never needs to run for it.
contract DeployMuseMaxxing is Script {
    /// @notice Deploys the token. The caller of this function's `new` is the deployer and receives
    /// the full supply.
    function deploy() public returns (MuseMaxxingToken token) {
        token = new MuseMaxxingToken();
    }

    /// @notice Broadcast entry point for `forge script`. The broadcasting account becomes the
    /// deployer and receives the whole supply.
    function run() external returns (MuseMaxxingToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
