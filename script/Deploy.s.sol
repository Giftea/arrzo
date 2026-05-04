// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {YieldStrategyRouter} from "../src/YieldStrategyRouter.sol";

/// Usage:
///   forge script script/Deploy.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify \
///     --sig "run(address,address,address,address,address)"
///     $ASSET $VEBTC $FEE_DIST $TROVE_MANAGER $PRICE_FEED
contract Deploy is Script {
    function run(
        address asset,
        address veBTC,
        address feeDist,
        address troveManager,
        address priceFeed
    ) external {
        address deployer = vm.envAddress("DEPLOYER");
        vm.startBroadcast(deployer);

        YieldStrategyRouter router =
            new YieldStrategyRouter(asset, veBTC, feeDist, troveManager, priceFeed, deployer);

        console2.log("YieldStrategyRouter:", address(router));

        vm.stopBroadcast();
    }
}
