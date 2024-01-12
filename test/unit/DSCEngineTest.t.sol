// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src//DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../script/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.t.sol";

contract DeployDSCTest is Test {
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    address user = makeAddr("user");

    // Liquidation
    address public liquidator = makeAddr("liquidator");

    uint256 public COLLATERAL_TO_COVER = 20 ether;
    uint256 amountToMint = 100 ether;

    DeployDSC private deployer;
    DecentralizedStableCoin private dscToken;
    DSCEngine private dscEngine;
    HelperConfig private config;
    address private wethUsdPriceFeed;
    address private wbtcUsdPriceFeed;
    address private weth;
    address private wbtc;

    uint256 private constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    //acreate address array of collateral tokens and pricefeeds
    address[] private collateralTokens;
    address[] private priceFeeds;

    function setUp() external {
        deployer = new DeployDSC();
        (dscToken, dscEngine, config) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock wethMock = ERC20Mock(weth);
        wethMock.mint(user, AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).mint(user, AMOUNT_COLLATERAL);
    }

    function testDeployDSC() external {
        assertEq(address(dscEngine), dscToken.owner());
    }

    function testGetUsdValue() public {
        uint256 wethUsdPrice = DSCEngine(dscEngine).getUsdValue(weth, 2 ether);
        uint256 expectedWethUsdPrice = 4000e18;
        assertEq(wethUsdPrice, expectedWethUsdPrice);
    }

    function testRevertsIfCollateralZero() public {
        ERC20Mock wethMock = ERC20Mock(weth);
        wethMock.approve(address(dscEngine), 10 ether);
        vm.prank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
    }

    function testRevertIfTokenLenghDoesntmatchpriceFeed() public {
        address[] memory _collateralTokens = new address[](2);
        _collateralTokens[0] = weth;
        _collateralTokens[1] = wbtc;

        address[] memory _priceFeeds = new address[](1);
        _priceFeeds[0] = wethUsdPriceFeed;

        vm.prank(user);
        vm.expectRevert(DSCEngine.DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeEqualLength.selector);
        DSCEngine dscEngineV2 = new DSCEngine(_collateralTokens, _priceFeeds, address(dscToken));
        console.log("dscEngineV2", address(dscEngineV2));
    }

    function testGetTokenAmountFromUsd() public {
        uint256 wethAmount = DSCEngine(dscEngine).getTokenAmounFromUSD(weth, 4000e18);
        uint256 expectedWethAmount = 2 ether;
        assertEq(wethAmount, expectedWethAmount);
    }

    function testGetUSDValue() public {
        uint256 wethUsdPrice = DSCEngine(dscEngine).getUsdValue(weth, 5 ether);
        uint256 expectedWethUsdPrice = 10000e18;
        assertEq(wethUsdPrice, expectedWethUsdPrice);
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock wethMock = new ERC20Mock("Wrapped Ether False", "WETHB", user, 1000e8);
        wethMock.approve(address(dscEngine), 10 ether);
        bytes memory errorRev = abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(wethMock));
        console.logBytes(errorRev);

        vm.prank(user);
        vm.expectRevert(errorRev);
        dscEngine.depositCollateral(address(wethMock), 10 ether);
    }

    modifier depositedCollateral() {
        ERC20Mock wethMock = ERC20Mock(weth);
        vm.startPrank(user);
        wethMock.approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testDepositCollateral() public depositedCollateral {
        (uint256 dscMinted, uint256 collateralBalance) = dscEngine.getAccountInformation(user);
        console.log("dscMinted", dscMinted);
        console.log("collateralBalance", collateralBalance);
        uint256 expectedDeposit = dscEngine.getTokenAmounFromUSD(weth, collateralBalance);
        console.log("expectedDeposit", expectedDeposit);
        assertEq(AMOUNT_COLLATERAL, expectedDeposit);
        assertEq(collateralBalance, AMOUNT_COLLATERAL * 2000);
        assertEq(dscMinted, 0);
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dscEngine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    function testGetDsc() public {
        address dscAddress = dscEngine.getDsc();
        assertEq(dscAddress, address(dscToken));
    }

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 collateralValue = dscEngine.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public depositedCollateral {
        uint256 collateralBalance = dscEngine.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = dscEngine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = dscEngine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dscEngine.getAccountInformation(user);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = dscEngine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, wethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory _collateralTokens = dscEngine.getCollateralTokens();
        assertEq(address(_collateralTokens[0]), weth);
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, COLLATERAL_TO_COVER);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_TO_COVER);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, amountToMint);
        dscToken.approve(address(dscEngine), amountToMint);
        dscEngine.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(user);
        assertEq(userDscMinted, 0);
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, COLLATERAL_TO_COVER);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_TO_COVER);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, amountToMint);
        dscToken.approve(address(dscEngine), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        dscEngine.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dscEngine.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) = 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dscEngine.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        dscToken.approve(address(dscEngine), amountToMint);
        dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dscToken.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dscToken.approve(address(dscEngine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(user, user, weth, AMOUNT_COLLATERAL);
        vm.startPrank(user);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalance = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalance, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    /**
     * function testRevertsIfTransferFails() public {
     *     // Arrange - Setup
     *     address owner = msg.sender;
     *     vm.prank(owner);
     *     MockFailedTransfer mockDsc = new MockFailedTransfer();
     *     tokenAddresses = [address(mockDsc)];
     *     feedAddresses = [ethUsdPriceFeed];
     *     vm.prank(owner);
     *     DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
     *     mockDsc.mint(user, amountCollateral);
     * 
     *     vm.prank(owner);
     *     mockDsc.transferOwnership(address(mockDsce));
     *     // Arrange - User
     *     vm.startPrank(user);
     *     ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
     *     // Act / Assert
     *     mockDsce.depositCollateral(address(mockDsc), amountCollateral);
     *     vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
     *     mockDsce.redeemCollateral(address(mockDsc), amountCollateral);
     *     vm.stopPrank();
     * }
     */
    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        dscEngine.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dscToken.approve(address(dscEngine), amountToMint);
        dscEngine.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dscToken.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(user);
        dscEngine.mintDsc(amountToMint);

        uint256 userBalance = dscToken.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(wethUsdPriceFeed).latestRoundData();
        amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    /**
     * function testRevertsIfMintFails() public {
     *     // Arrange - Setup
     *     MockFailedMintDSC mockDsc = new MockFailedMintDSC();
     *     tokenAddresses = [weth];
     *     feedAddresses = [ethUsdPriceFeed];
     *     address owner = msg.sender;
     *     vm.prank(owner);
     *     DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
     *     mockDsc.transferOwnership(address(mockDsce));
     *     // Arrange - User
     *     vm.startPrank(user);
     *     ERC20Mock(weth).approve(address(mockDsce), amountCollateral);
     * 
     *     vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
     *     mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
     *     vm.stopPrank();
     * }
     */
    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dscToken.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(wethUsdPriceFeed).latestRoundData();
        amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }
}
