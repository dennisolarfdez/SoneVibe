// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../interfaces/IV_MasterEnhanced.sol";
import "../interfaces/IVibePriceOracle.sol";
import "../interfaces/IV_cTokenMinimal.sol";
import "../proxy/V_UnitAdminStorage.sol";
import "./V_MasterEnhancedUnitSupport.sol";

contract V_MasterEnhanced is V_UnitAdminStorage, V_MasterEnhancedUnitSupport, IV_MasterEnhanced {
    // Oráculo (proxy-inicializable)
    address public override oracle;

    // Mercados
    mapping(address => bool) public markets;
    address[] public allMarkets;

    // Factores por mercado
    mapping(address => uint256) public marketCollateralFactorMantissa;
    mapping(address => uint256) public marketLiquidationThresholdMantissa;

    // Membership (colateral activo)
    mapping(address => mapping(address => bool)) public accountMembership;

    // Caps
    mapping(address => uint256) public override marketSupplyCaps;
    mapping(address => uint256) public override marketBorrowCaps;

    // Parámetros globales de riesgo (deben setearse vía setters / initializeRiskParams)
    uint256 public override closeFactorMantissa;
    uint256 public override liquidationIncentiveMantissa;

    // Pausas
    address public pauseGuardian;
    bool public borrowPaused;
    bool public redeemPaused;
    bool public liquidatePaused;

    // Eventos
    event MarketListed(address indexed cToken);
    event CollateralFactorUpdated(address indexed cToken, uint256 oldCF, uint256 newCF);
    event LiquidationThresholdUpdated(address indexed cToken, uint256 oldLT, uint256 newLT);
    event MarketEntered(address indexed account, address indexed cToken);
    event MarketExited(address indexed account, address indexed cToken);
    event CapsUpdated(address indexed cToken, uint256 supplyCap, uint256 borrowCap);
    event Initialized(address oracle, address admin);

    event CloseFactorUpdated(uint256 oldCloseFactor, uint256 newCloseFactor);
    event LiquidationIncentiveUpdated(uint256 oldIncentive, uint256 newIncentive);
    event RiskParamsInitialized(uint256 closeFactor, uint256 liquidationIncentive);

    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event BorrowPaused(bool paused);
    event RedeemPaused(bool paused);
    event LiquidatePaused(bool paused);

    modifier onlyAdmin() { require(msg.sender == admin, "master: !admin"); _; }

    function isComptroller() external pure override returns (bool) { return true; }

    // Inicializa sólo el oráculo
    function initialize(address _oracle) external {
        require(oracle == address(0), "initialized");
        require(msg.sender == admin, "master: only admin");
        oracle = _oracle;
        emit Initialized(_oracle, admin);
    }

    // Inicializa riesgo si ambos están en cero
    function initializeRiskParams(uint256 _closeFactor, uint256 _incentive) external onlyAdmin {
        require(closeFactorMantissa == 0 && liquidationIncentiveMantissa == 0, "risk already set");
        require(_closeFactor > 0 && _closeFactor <= 1e18, "bad closeFactor");
        require(_incentive >= 1e18 && _incentive <= 1.2e18, "bad incentive");
        emit CloseFactorUpdated(closeFactorMantissa, _closeFactor);
        emit LiquidationIncentiveUpdated(liquidationIncentiveMantissa, _incentive);
        closeFactorMantissa = _closeFactor;
        liquidationIncentiveMantissa = _incentive;
        emit RiskParamsInitialized(_closeFactor, _incentive);
    }

    function setCloseFactor(uint256 newCloseFactor) external onlyAdmin {
        require(newCloseFactor > 0 && newCloseFactor <= 1e18, "bad close factor");
        emit CloseFactorUpdated(closeFactorMantissa, newCloseFactor);
        closeFactorMantissa = newCloseFactor;
    }

    function setLiquidationIncentive(uint256 newIncentive) external onlyAdmin {
        require(newIncentive >= 1e18 && newIncentive <= 1.2e18, "bad incentive");
        emit LiquidationIncentiveUpdated(liquidationIncentiveMantissa, newIncentive);
        liquidationIncentiveMantissa = newIncentive;
    }

    // Guardian / pausas
    function setPauseGuardian(address g) external onlyAdmin {
        emit PauseGuardianUpdated(pauseGuardian, g);
        pauseGuardian = g;
    }

    function setBorrowPaused(bool paused) external {
        require(msg.sender == admin || (msg.sender == pauseGuardian && paused), "no auth");
        borrowPaused = paused;
        emit BorrowPaused(paused);
    }

    function setRedeemPaused(bool paused) external {
        require(msg.sender == admin || (msg.sender == pauseGuardian && paused), "no auth");
        redeemPaused = paused;
        emit RedeemPaused(paused);
    }

    function setLiquidatePaused(bool paused) external {
        require(msg.sender == admin || (msg.sender == pauseGuardian && paused), "no auth");
        liquidatePaused = paused;
        emit LiquidatePaused(paused);
    }

    // Mercados
    function supportMarket(address cToken) external onlyAdmin {
        require(!markets[cToken], "market exists");
        markets[cToken] = true;
        allMarkets.push(cToken);
        emit MarketListed(cToken);
    }

    function setFactors(address cToken, uint256 cf, uint256 lt) external onlyAdmin {
        require(markets[cToken], "not listed");
        require(cf <= 0.9e18 && lt <= 0.95e18 && lt >= cf, "invalid factors");
        emit CollateralFactorUpdated(cToken, marketCollateralFactorMantissa[cToken], cf);
        emit LiquidationThresholdUpdated(cToken, marketLiquidationThresholdMantissa[cToken], lt);
        marketCollateralFactorMantissa[cToken] = cf;
        marketLiquidationThresholdMantissa[cToken] = lt;
    }

    function setCaps(address cToken, uint256 supplyCapUnderlying, uint256 borrowCapUnderlying) external onlyAdmin {
        marketSupplyCaps[cToken] = supplyCapUnderlying;
        marketBorrowCaps[cToken] = borrowCapUnderlying;
        emit CapsUpdated(cToken, supplyCapUnderlying, borrowCapUnderlying);
    }

    // Membership
    function enterMarkets(address[] calldata cTokens) external {
        for (uint i; i < cTokens.length; i++) {
            require(markets[cTokens[i]], "market!");
            accountMembership[msg.sender][cTokens[i]] = true;
            emit MarketEntered(msg.sender, cTokens[i]);
        }
    }

    function exitMarket(address cToken) external {
        require(accountMembership[msg.sender][cToken], "not member");
        accountMembership[msg.sender][cToken] = false;
        require(_isAccountHealthy(msg.sender), "exit unhealthy");
        emit MarketExited(msg.sender, cToken);
    }

    function getAssetsIn(address account) public view returns (address[] memory list) {
        uint count;
        for (uint i; i < allMarkets.length; i++)
            if (accountMembership[account][allMarkets[i]]) count++;
        list = new address[](count);
        uint idx;
        for (uint i; i < allMarkets.length; i++)
            if (accountMembership[account][allMarkets[i]]) list[idx++] = allMarkets[i];
    }

    // Liquidez
    struct LiquidityData { uint256 collateralUSD; uint256 liquidationUSD; uint256 borrowUSD; }

    function getAccountLiquidity(address account) public view returns (LiquidityData memory ld) {
        for (uint i; i < allMarkets.length; i++) {
            address m = allMarkets[i];
            if (!markets[m]) continue;

            IV_cTokenMinimal ct = IV_cTokenMinimal(m);
            uint256 price = IVibePriceOracle(oracle).getUnderlyingPrice(m);
            if (price == 0) continue;

            uint256 bal = ct.balanceOf(account);
            uint256 bor = ct.borrowBalance(account);
            uint8 dec = ct.underlyingDecimals();
            uint256 exRate = ct.exchangeRateStored();

            if (bal > 0 && accountMembership[account][m]) {
                uint256 underlyingSupplied = (bal * exRate) / 1e18;
                uint256 valueUSD = (underlyingSupplied * price) / 1e18;
                ld.collateralUSD += (valueUSD * marketCollateralFactorMantissa[m]) / 1e18;
                ld.liquidationUSD += (valueUSD * marketLiquidationThresholdMantissa[m]) / 1e18;
            }
            if (bor > 0) {
                uint256 borrowVal = (bor * price) / (10 ** uint256(dec));
                ld.borrowUSD += borrowVal;
            }
        }
    }

    function _isAccountHealthy(address account) internal view returns (bool) {
        LiquidityData memory ld = getAccountLiquidity(account);
        return ld.borrowUSD <= ld.liquidationUSD;
    }

    // Validaciones cTokens
    function canBorrow(address account, address cToken, uint256 amount) external view override returns (bool) {
        if (borrowPaused) return false;
        if (!accountMembership[account][cToken]) return false;
        LiquidityData memory ld = getAccountLiquidity(account);
        IV_cTokenMinimal ct = IV_cTokenMinimal(cToken);
        uint8 dec = ct.underlyingDecimals();
        uint256 price = IVibePriceOracle(oracle).getUnderlyingPrice(cToken);
        if (price == 0) return false;
        uint256 amountUSD = (amount * price) / (10 ** uint256(dec));
        return ld.collateralUSD >= ld.borrowUSD + amountUSD;
    }

    function canRedeem(address account, address cToken, uint256 cTokenAmount) external view override returns (bool) {
        if (redeemPaused) return false;
        IV_cTokenMinimal ct = IV_cTokenMinimal(cToken);
        if (!accountMembership[account][cToken]) {
            return cTokenAmount <= ct.balanceOf(account);
        }
        LiquidityData memory ldBefore = getAccountLiquidity(account);
        uint256 price = IVibePriceOracle(oracle).getUnderlyingPrice(cToken);
        if (price == 0) return false;
        uint256 exRate = ct.exchangeRateStored();
        uint256 underlyingRedeem = (cTokenAmount * exRate) / 1e18;
        uint256 valueUSDFull = (underlyingRedeem * price) / 1e18;

        uint256 cf = marketCollateralFactorMantissa[cToken];
        uint256 lt = marketLiquidationThresholdMantissa[cToken];

        uint256 cfDelta = (valueUSDFull * cf) / 1e18;
        if (cfDelta > ldBefore.collateralUSD) return false;
        uint256 ltDelta = (valueUSDFull * lt) / 1e18;
        if (ltDelta > ldBefore.liquidationUSD) return false;

        uint256 newCollateralUSD = ldBefore.collateralUSD - cfDelta;
        uint256 newLiquidationUSD = ldBefore.liquidationUSD - ltDelta;

        return ldBefore.borrowUSD <= newLiquidationUSD && newCollateralUSD >= ldBefore.borrowUSD;
    }

    function seizeAllowed(
        address borrower,
        address /*liquidator*/,
        address /*cTokenCollateral*/,
        address /*cTokenBorrowed*/,
        uint256 /*seizeTokens*/
    ) external view override returns (bool) {
        if (liquidatePaused) return false;
        LiquidityData memory ld = getAccountLiquidity(borrower);
        return ld.borrowUSD > ld.liquidationUSD;
    }

    // Helpers bots
    function previewCloseFactorMaxRepay(address cTokenBorrowed, address borrower) external view returns (uint256) {
        IV_cTokenMinimal ct = IV_cTokenMinimal(cTokenBorrowed);
        uint256 debt = ct.borrowBalance(borrower);
        if (debt == 0) return 0;
        return (debt * closeFactorMantissa) / 1e18; // floor
    }

    function previewSeizeTokens(address cTokenBorrowed, address cTokenCollateral, uint256 repayAmount)
        external
        view
        returns (uint256 seizeCTokens, uint256 seizeUnderlyingRaw, uint256 seizeUSD)
    {
        IVibePriceOracle o = IVibePriceOracle(oracle);
        uint256 priceBorrowed = o.getUnderlyingPrice(cTokenBorrowed);
        require(priceBorrowed > 0, "oracle borrowed");
        uint256 priceCollateral = o.getUnderlyingPrice(cTokenCollateral);
        require(priceCollateral > 0, "oracle collateral");

        uint8 decBorrow = IV_cTokenMinimal(cTokenBorrowed).underlyingDecimals();
        uint256 repayUSD = (repayAmount * priceBorrowed) / (10 ** uint256(decBorrow));

        require(liquidationIncentiveMantissa >= 1e18, "bad incentive");
        seizeUSD = (repayUSD * liquidationIncentiveMantissa) / 1e18;

        uint8 decCol = IV_cTokenMinimal(cTokenCollateral).underlyingDecimals();
        seizeUnderlyingRaw = (seizeUSD * (10 ** uint256(decCol))) / priceCollateral;

        uint256 normalized;
        if (decCol < 18) normalized = seizeUnderlyingRaw * (10 ** (18 - decCol));
        else if (decCol > 18) normalized = seizeUnderlyingRaw / (10 ** (decCol - 18));
        else normalized = seizeUnderlyingRaw;

        uint256 exRateCol = IV_cTokenMinimal(cTokenCollateral).exchangeRateStored();
        seizeCTokens = (normalized * 1e18) / exRateCol;
    }
}