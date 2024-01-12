// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "forge-std/Script.sol";
import {DSCEngine} from "../src//DSCEngine.sol";
import {DecentralizedStableCoin} from "../src//DecentralizedStableCoin.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSC is Script {
    DSCEngine public dscEngine;
    DecentralizedStableCoin public dscToken;

    function run() external returns (DecentralizedStableCoin, DSCEngine, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc,) =
            helperConfig.activeNetworkConfig();

        //array of addresses
        address[] memory _collateralTokens = new address[](2);
        _collateralTokens[0] = weth;
        _collateralTokens[1] = wbtc;

        //array of addresses
        address[] memory _priceFeeds = new address[](2);
        _priceFeeds[0] = wethUsdPriceFeed;
        _priceFeeds[1] = wbtcUsdPriceFeed;

        vm.startBroadcast();
        dscToken = new DecentralizedStableCoin();
        dscEngine = new DSCEngine(_collateralTokens, _priceFeeds, address(dscToken));
        dscToken.transferOwnership(address(dscEngine));
        vm.stopBroadcast();
        return (dscToken, dscEngine, helperConfig);
    }
}
