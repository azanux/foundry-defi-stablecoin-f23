// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {console}   from "forge-std/console.sol";

/**
 * @title DSCEngine
 * @author Charles Azanlekor
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeEqualLength();
    error DSCEngine__TokenNotAllowed(address tokenAddress);
    error DSCEngine__DepositFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__NotEnoughCollateral();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved(uint256 healthFactor);

     using OracleLib for AggregatorV3Interface;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    DecentralizedStableCoin private immutable i_dsc;
    address[] private s_collateralTokens;

    mapping(address token => address priceFeeds) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256)) private s_collateralDeposited;
    mapping(address user => uint256) private s_dscMinted;

    uint256 private constant ADDITIONAL_FEED_PRECIISON = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;


    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(_token);
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeEqualLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amount)
        public
        moreThanZero(amount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amount;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amount);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amount);
        require(success, "DSCEngine: deposit failed");

        if (!success) {
            revert DSCEngine__DepositFailed();
        }
    }


    function _redeemCollateral(address tokenColllateral, uint256 amoutCollateral, address from, address to) private {
        s_collateralDeposited[from][tokenColllateral] -= amoutCollateral;
        bool success = IERC20(tokenColllateral).transfer(to, amoutCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        emit CollateralRedeemed(from, to, tokenColllateral, amoutCollateral);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     *
     * @param tokenCollateralAddress The ERC20 token address of the collateral you're depositing
     * @param amountCollateral  The amount of collateral you're depositing
     * @param amountDscToMint  The amount of DSC you want to mint
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) public moreThanZero(amountCollateral) moreThanZero(amountDscToMint) {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @param amountDscToMint: The amount of DSC you want to mint
     * You can only mint DSC if you hav enough collateral
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        _reverIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function getAccountCollateralValue(address _user) public view returns (uint256) {
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address tokenAddress = s_collateralTokens[i];
            uint256 collateralAmount = s_collateralDeposited[_user][tokenAddress];
            totalCollateralValueInUsd += getUsdValue(tokenAddress, collateralAmount);
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (_amount * uint256(price) * ADDITIONAL_FEED_PRECIISON) / PRECISION;
    }

    function _reverIfHealthFactorIsBroken(address _user) internal view {
        uint256 healthFactor = _healthFactor(_user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(healthFactor);
        }
    }

    function _healthFactor(address _user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function _getAccountInformation(address _user) private view returns (uint256, uint256) {
        uint256 totalDscMinted = s_dscMinted[_user];
        uint256 collateralValueInUsd = getAccountCollateralValue(_user);
        return (totalDscMinted, collateralValueInUsd);
    }

    function burnDsc(uint256 amount) public nonReentrant moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _reverIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @dev Low-level internal function to burn DSC
     * @param amount The amount of DSC you want to burn
     * @param onBehalf The address of the user you're burning DSC for
     * @param dscFrom The address of the user you're taking the DSC from
     */
    function _burnDsc(uint256 amount, address onBehalf, address dscFrom) private {
        uint256 dscMinted = s_dscMinted[onBehalf];
        if (amount > dscMinted) {
            revert DSCEngine__NotEnoughCollateral();
        }

        s_dscMinted[onBehalf] -= amount;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    }

function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
        moreThanZero(amountCollateral)
    {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /**
     *
     * @param tokenCollateral The token address of the collateral you're depositing
     * @param user The address of the user you're liquidating
     * @param debtToCover The amount of DSC you want to cover
     * @notice You can partially liquidate a user, and get a liquidation bonus for trading the users funds
     *
     */
    function liquidate(address tokenCollateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 _starthealthFactor = _healthFactor(user);

        if (_starthealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }

    
        uint256 tokenAmountFromDebtCovered = getTokenAmounFromUSD(tokenCollateral, debtToCover);

        
        //we are taking to liquidator 10% bonus of the collateral
        uint256 tokenAmountFromDebtCoveredWithBonus =
            tokenAmountFromDebtCovered * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCoveredWithBonus + tokenAmountFromDebtCovered;
        _redeemCollateral(tokenCollateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 _endingHealthFactor = _healthFactor(user);

        if (_endingHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved(_endingHealthFactor);
        }
        _reverIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     * @notice This function will redeem your collateral.
     * @notice If you have DSC minted, you will not be able to redeem until you burn your DSC
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function getTokenAmounFromUSD(address token, uint256 usdAmountInMei) public view returns (uint256) {
        
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        console.log("###### usdAmountInMei ", address(token));
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        console.log("###### price ", uint256(price));
        uint256 tokenAmountFromDebtCovered = ((usdAmountInMei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECIISON));
        console.log("token amount", tokenAmountFromDebtCovered);
        return ((usdAmountInMei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECIISON));
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECIISON;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
