// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../interfaces/IV_MasterEnhanced.sol";
import "../interfaces/IVibePriceOracle.sol";
import "../libraries/SafeTransferLib.sol";

interface IERC20Basic {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IInterestRateModel {
    function isInterestRateModel() external pure returns (bool);
    function getBorrowRate(uint cash, uint borrows, uint reserves) external view returns (uint);
    function getSupplyRate(uint cash, uint borrows, uint reserves, uint reserveFactorMantissa) external view returns (uint);
}

contract V_cERC20_ExtendedInterest {
    // Identidad
    string public name;
    string public symbol;
    uint8 public decimals; // cToken = 18

    // Componentes
    address public immutable underlying;
    IV_MasterEnhanced public immutable comptroller;
    address public guardian;

    // Supply (cTokens)
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Interés (global)
    uint256 public accrualBlockNumber;
    uint256 public borrowIndex;          // 1e18 inicial
    uint256 public totalBorrows;         // unidades nativas del underlying
    uint256 public totalReserves;        // unidades nativas del underlying
    uint256 public reserveFactorMantissa;
    IInterestRateModel public interestRateModel;

    // Interés (por cuenta)
    mapping(address => uint256) public borrowPrincipal;
    mapping(address => uint256) public accountBorrowIndex;

    // Exchange rate inicial
    uint256 public exchangeRateInitialMantissa = 1e18;

    // Guard reentrancia
    uint8 private _status;
    uint8 private constant _NOT_ENTERED = 1;
    uint8 private constant _ENTERED = 2;

    // Eventos
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Mint(address indexed minter, uint256 underlyingAmount, uint256 cTokensMinted);
    event Redeem(address indexed redeemer, uint256 underlyingAmount, uint256 cTokensBurned);
    event Borrow(address indexed borrower, uint256 amount);
    event Repay(address indexed payer, address indexed borrower, uint256 amount);
    event LiquidateBorrow(address indexed liquidator, address indexed borrower, uint256 repayAmount, address cTokenCollateral, uint256 seizeTokens);
    event GuardianSet(address indexed guardian);
    event AccrueInterest(uint256 interestAccumulated, uint256 borrowIndexNew, uint256 totalBorrowsNew, uint256 totalReservesNew);
    event NewReserveFactor(uint256 oldFactor, uint256 newFactor);
    event NewInterestRateModel(address oldModel, address newModel);

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrancy");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "not guardian");
        _;
    }

    constructor(
        string memory _n,
        string memory _s,
        address _underlying,
        address _comptroller,
        address _guardian,
        address _irm,
        uint256 _reserveFactorMantissa
    ) {
        name = _n;
        symbol = _s;
        decimals = 18;

        underlying = _underlying;
        comptroller = IV_MasterEnhanced(_comptroller);
        require(comptroller.isComptroller(), "invalid comptroller");

        guardian = _guardian;
        emit GuardianSet(_guardian);

        IInterestRateModel irm = IInterestRateModel(_irm);
        require(irm.isInterestRateModel(), "bad IRM");
        interestRateModel = irm;
        reserveFactorMantissa = _reserveFactorMantissa;

        borrowIndex = 1e18;
        accrualBlockNumber = block.number;

        _status = _NOT_ENTERED;
    }

    // Compatibilidad + helpers
    function underlyingAddress() external view returns (address) { return underlying; }
    // Nota: NO se declara underlying() porque el getter se autogenera por la variable pública `underlying`

    function underlyingDecimals() public view returns (uint8) { return IERC20Basic(underlying).decimals(); }

    // Normalización a 18
    function _toNormalized(uint256 raw) internal view returns (uint256) {
        uint8 ud = underlyingDecimals();
        if (ud == 18) return raw;
        if (ud < 18) return raw * (10 ** (18 - ud));
        return raw / (10 ** (ud - 18));
    }
    function _fromNormalized(uint256 norm) internal view returns (uint256) {
        uint8 ud = underlyingDecimals();
        if (ud == 18) return norm;
        if (ud < 18) return norm / (10 ** (18 - ud));
        return norm * (10 ** (ud - 18));
    }

    // Admin
    function setGuardian(address g) external onlyGuardian {
        guardian = g;
        emit GuardianSet(g);
    }
    function setReserveFactor(uint256 newFactor) external onlyGuardian {
        require(newFactor <= 0.25e18, "too high");
        emit NewReserveFactor(reserveFactorMantissa, newFactor);
        reserveFactorMantissa = newFactor;
    }
    function setInterestRateModel(address newModel) external onlyGuardian {
        IInterestRateModel irm = IInterestRateModel(newModel);
        require(irm.isInterestRateModel(), "bad model");
        emit NewInterestRateModel(address(interestRateModel), newModel);
        interestRateModel = irm;
    }

    // ERC20-like
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "insufficient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    // Intereses
    function accrueInterest() public {
        uint256 currentBlock = block.number;
        uint256 delta = currentBlock - accrualBlockNumber;
        if (delta == 0) return;

        uint256 cash = IERC20Basic(underlying).balanceOf(address(this));
        uint256 borrows = totalBorrows;
        uint256 reserves = totalReserves;

        uint256 borrowRate = interestRateModel.getBorrowRate(cash, borrows, reserves);
        // límite de seguridad (ajusta para tu red)
        require(borrowRate <= 5e13, "rate too high"); // ~0.005% por bloque

        uint256 interestAccumulated = (borrowRate * delta * borrows) / 1e18;
        uint256 totalBorrowsNew = borrows + interestAccumulated;
        uint256 reservesAdded = (interestAccumulated * reserveFactorMantissa) / 1e18;
        uint256 totalReservesNew = reserves + reservesAdded;
        uint256 borrowIndexNew = borrowIndex + ((borrowRate * delta * borrowIndex) / 1e18);

        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;
        borrowIndex = borrowIndexNew;
        accrualBlockNumber = currentBlock;

        emit AccrueInterest(interestAccumulated, borrowIndexNew, totalBorrowsNew, totalReservesNew);
    }

    // Exchange Rate
    function exchangeRateStored() public view returns (uint256) {
        if (totalSupply == 0) return exchangeRateInitialMantissa;
        uint256 cashNorm = _toNormalized(IERC20Basic(underlying).balanceOf(address(this)));
        uint256 borNorm  = _toNormalized(totalBorrows);
        uint256 resNorm  = _toNormalized(totalReserves);
        uint256 numerator = cashNorm + borNorm - resNorm;
        return (numerator * 1e18) / totalSupply;
    }
    function exchangeRateCurrent() external returns (uint256) {
        accrueInterest();
        return exchangeRateStored();
    }

    // Mint / Redeem
    function mint(uint256 amount) external nonReentrant {
        accrueInterest();
        require(amount > 0, "mint zero");
        SafeTransferLib.safeTransferFrom(underlying, msg.sender, address(this), amount);
        uint256 exRate = exchangeRateStored();
        uint256 cTokens = (_toNormalized(amount) * 1e18) / exRate;
        totalSupply += cTokens;
        balanceOf[msg.sender] += cTokens;
        emit Mint(msg.sender, amount, cTokens);
        emit Transfer(address(0), msg.sender, cTokens);
    }
    function redeem(uint256 cTokenAmount) external nonReentrant {
        accrueInterest();
        require(cTokenAmount > 0 && balanceOf[msg.sender] >= cTokenAmount, "redeem invalid");
        require(comptroller.canRedeem(msg.sender, address(this), cTokenAmount), "unhealthy after redeem");
        uint256 exRate = exchangeRateStored();
        uint256 underlyingNorm = (cTokenAmount * exRate) / 1e18;
        uint256 underlyingRaw = _fromNormalized(underlyingNorm);
        balanceOf[msg.sender] -= cTokenAmount;
        totalSupply -= cTokenAmount;
        SafeTransferLib.safeTransfer(underlying, msg.sender, underlyingRaw);
        emit Redeem(msg.sender, underlyingRaw, cTokenAmount);
        emit Transfer(msg.sender, address(0), cTokenAmount);
    }

    // Borrow / Repay
    function _currentBorrowBalance(address account) internal view returns (uint256) {
        uint256 p = borrowPrincipal[account];
        if (p == 0) return 0;
        uint256 idx = accountBorrowIndex[account];
        if (idx == 0) return 0;
        return (p * borrowIndex) / idx;
    }
    function borrowBalance(address account) external view returns (uint256) {
        return _currentBorrowBalance(account);
    }

    function borrow(uint256 amount) external nonReentrant {
        accrueInterest();
        require(amount > 0, "borrow zero");
        require(comptroller.canBorrow(msg.sender, address(this), amount), "insufficient collateral");
        uint256 prev = _currentBorrowBalance(msg.sender);
        uint256 newBal = prev + amount;
        borrowPrincipal[msg.sender] = (newBal * 1e18) / borrowIndex;
        accountBorrowIndex[msg.sender] = borrowIndex;
        totalBorrows += amount;
        SafeTransferLib.safeTransfer(underlying, msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        accrueInterest();
        require(amount > 0, "repay zero");
        uint256 userBorrow = _currentBorrowBalance(msg.sender);
        require(userBorrow > 0, "no debt");
        SafeTransferLib.safeTransferFrom(underlying, msg.sender, address(this), amount);
        uint256 repayFinal = amount >= userBorrow ? userBorrow : amount;
        uint256 newBorrow = userBorrow - repayFinal;
        if (newBorrow == 0) {
            borrowPrincipal[msg.sender] = 0;
            accountBorrowIndex[msg.sender] = borrowIndex;
        } else {
            borrowPrincipal[msg.sender] = (newBorrow * 1e18) / borrowIndex;
            accountBorrowIndex[msg.sender] = borrowIndex;
        }
        totalBorrows -= repayFinal;
        emit Repay(msg.sender, msg.sender, repayFinal);
    }

    // Liquidaciones (incautar primero)
    function liquidateBorrow(address borrower, uint256 repayAmount, address cTokenCollateral) external nonReentrant {
        accrueInterest();
        if (cTokenCollateral != address(this)) {
            V_cERC20_ExtendedInterest(cTokenCollateral).accrueInterest();
        }

        require(borrower != msg.sender, "self liquidate");

        uint256 borrowerDebtPrev = _currentBorrowBalance(borrower);
        require(borrowerDebtPrev > 0, "no debt");

        require(
            comptroller.seizeAllowed(borrower, msg.sender, cTokenCollateral, address(this), 0),
            "not liquidatable"
        );

        uint256 cf = comptroller.closeFactorMantissa();
        uint256 maxRepay = (borrowerDebtPrev * cf + 1e18 - 1) / 1e18; // ceiling
        if (maxRepay > borrowerDebtPrev) maxRepay = borrowerDebtPrev;

        if (repayAmount > maxRepay) repayAmount = maxRepay;
        if (repayAmount > borrowerDebtPrev) repayAmount = borrowerDebtPrev;
        require(repayAmount > 0, "repay zero");

        uint256 seizeCTokens = _computeSeizeCTokens(cTokenCollateral, repayAmount);
        require(seizeCTokens > 0, "seize zero");

        if (cTokenCollateral == address(this)) {
            require(balanceOf[borrower] >= seizeCTokens, "insufficient collateral tokens");
        } else {
            require(
                V_cERC20_ExtendedInterest(cTokenCollateral).balanceOf(borrower) >= seizeCTokens,
                "insufficient collateral tokens"
            );
        }

        SafeTransferLib.safeTransferFrom(underlying, msg.sender, address(this), repayAmount);

        if (cTokenCollateral == address(this)) {
            _seizeInternal(msg.sender, borrower, seizeCTokens);
        } else {
            V_cERC20_ExtendedInterest(cTokenCollateral).seize(msg.sender, borrower, seizeCTokens);
        }

        uint256 newBorrow = borrowerDebtPrev - repayAmount;
        if (newBorrow == 0) {
            borrowPrincipal[borrower] = 0;
            accountBorrowIndex[borrower] = borrowIndex;
        } else {
            borrowPrincipal[borrower] = (newBorrow * 1e18) / borrowIndex;
            accountBorrowIndex[borrower] = borrowIndex;
        }
        totalBorrows -= repayAmount;

        emit LiquidateBorrow(msg.sender, borrower, repayAmount, cTokenCollateral, seizeCTokens);
    }

    function seize(address liquidator, address borrower, uint256 seizeTokens) external nonReentrant {
        require(
            comptroller.seizeAllowed(borrower, liquidator, address(this), msg.sender, seizeTokens),
            "seize not allowed"
        );
        _seizeInternal(liquidator, borrower, seizeTokens);
    }

    function _seizeInternal(address liquidator, address borrower, uint256 seizeTokens) internal {
        require(balanceOf[borrower] >= seizeTokens, "insufficient collateral tokens");
        balanceOf[borrower] -= seizeTokens;
        balanceOf[liquidator] += seizeTokens;
        emit Transfer(borrower, liquidator, seizeTokens);
    }

    // Preview
    function previewSeizeTokens(address cTokenCollateral, uint256 repayAmount) external view returns (uint256) {
        return _computeSeizeCTokens(cTokenCollateral, repayAmount);
    }

    function _computeSeizeCTokens(address cTokenCollateral, uint256 repayAmount) internal view returns (uint256) {
        IVibePriceOracle o = IVibePriceOracle(comptroller.oracle());

        uint256 priceBorrowed = o.getUnderlyingPrice(address(this));
        require(priceBorrowed > 0, "oracle borrowed");

        uint256 priceCollateral = o.getUnderlyingPrice(cTokenCollateral);
        require(priceCollateral > 0, "oracle collateral");

        uint8 decBorrow = underlyingDecimals();
        uint256 repayUSD = (repayAmount * priceBorrowed) / (10 ** decBorrow);

        uint256 incentive = comptroller.liquidationIncentiveMantissa();
        require(incentive >= 1e18, "bad incentive");
        uint256 seizeUSD = (repayUSD * incentive) / 1e18;

        address uCol = V_cERC20_ExtendedInterest(cTokenCollateral).underlyingAddress();
        uint8 decCol = IERC20Basic(uCol).decimals();
        uint256 seizeUnderlyingRaw = (seizeUSD * (10 ** decCol)) / priceCollateral;

        uint256 normalized;
        if (decCol < 18) normalized = seizeUnderlyingRaw * (10 ** (18 - decCol));
        else if (decCol > 18) normalized = seizeUnderlyingRaw / (10 ** (decCol - 18));
        else normalized = seizeUnderlyingRaw;

        uint256 exRateCol = V_cERC20_ExtendedInterest(cTokenCollateral).exchangeRateStored();
        return (normalized * 1e18) / exRateCol;
    }
}