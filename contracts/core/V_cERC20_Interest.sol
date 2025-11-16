// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../interfaces/IV_MasterEnhanced.sol";
import "../interfaces/IVibePriceOracle.sol";
import "../libraries/SafeTransferLib.sol";
import "../risk/IInterestRateModel.sol";

interface IERC20Decimals { function decimals() external view returns (uint8); }

contract V_cERC20_Interest {
    // EXISTENTES
    string public name;
    string public symbol;
    uint8 public decimals;
    address public immutable underlying;
    IV_MasterEnhanced public immutable comptroller;
    address public guardian;

    // NUEVOS ESTADOS DE INTERÉS
    uint256 public accrualBlockNumber;
    uint256 public borrowIndex;          // inicial = 1e18
    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public reserveFactorMantissa; // ej 0.1e18
    IInterestRateModel public interestRateModel;

    // Supply
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // Borrow principal “base”
    mapping(address => uint256) public borrowPrincipal;
    mapping(address => uint256) public accountBorrowIndex;

    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public exchangeRateMantissa = 1e18;

    uint8 private _status;
    uint8 private constant _NOT_ENTERED = 1;
    uint8 private constant _ENTERED = 2;

    // EVENTS
    event AccrueInterest(uint256 interestAccumulated, uint256 borrowIndexNew, uint256 totalBorrowsNew, uint256 totalReservesNew);
    event NewReserveFactor(uint256 oldFactor, uint256 newFactor);
    event NewInterestRateModel(address oldModel, address newModel);

    // (Mantén tus eventos previos: Mint, Redeem, Borrow, Repay, LiquidateBorrow, Transfer, etc.)

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrancy");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "guardian");
        _;
    }

    constructor(
        string memory _n,
        string memory _s,
        address _underlying,
        address _comptroller,
        address _guardian,
        address _irm,
        uint256 _reserveFactor
    ) {
        name = _n;
        symbol = _s;
        decimals = 18;
        underlying = _underlying;
        comptroller = IV_MasterEnhanced(_comptroller);
        require(comptroller.isComptroller(), "bad comptroller");
        guardian = _guardian;
        interestRateModel = IInterestRateModel(_irm);
        require(interestRateModel.isInterestRateModel(), "bad irm");
        reserveFactorMantissa = _reserveFactor;
        borrowIndex = 1e18;
        accrualBlockNumber = block.number;
        _status = _NOT_ENTERED;
    }

    // ===== Interest Logic =====
    function accrueInterest() public {
        uint currentBlock = block.number;
        uint delta = currentBlock - accrualBlockNumber;
        if (delta == 0) return;

        uint cash = IERC20Decimals(underlying).decimals(); // OJO: esto está mal, debes usar balance real:
        // CORRECCIÓN: uint cash = IERC20(underlying).balanceOf(address(this));

        cash = IERC20(underlying).balanceOf(address(this));
        uint borrows = totalBorrows;
        uint reserves = totalReserves;

        uint borrowRate = interestRateModel.getBorrowRate(cash, borrows, reserves);
        require(borrowRate <= 0.0005e18, "rate too high"); // ejemplo límite

        uint interestAccumulated = borrowRate * delta * borrows / 1e18;
        uint totalBorrowsNew = borrows + interestAccumulated;
        uint reservesAdded = interestAccumulated * reserveFactorMantissa / 1e18;
        uint totalReservesNew = reserves + reservesAdded;
        uint borrowIndexNew = borrowIndex + (borrowRate * delta * borrowIndex / 1e18);

        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;
        borrowIndex = borrowIndexNew;
        accrualBlockNumber = currentBlock;

        emit AccrueInterest(interestAccumulated, borrowIndexNew, totalBorrowsNew, totalReservesNew);
    }

    function borrowBalance(address account) public view returns (uint256) {
        uint principal = borrowPrincipal[account];
        if (principal == 0) return 0;
        uint index = accountBorrowIndex[account];
        return principal * borrowIndex / index;
    }

    // ===== Borrow =====
    function borrow(uint256 amount) external nonReentrant {
        accrueInterest();
        require(amount > 0, "borrow zero");
        require(comptroller.canBorrow(msg.sender, address(this), amount), "insufficient collateral");

        // Actualizar deuda usuario
        uint prevBalance = borrowBalance(msg.sender);
        uint newBalance = prevBalance + amount;
        borrowPrincipal[msg.sender] = newBalance * 1e18 / borrowIndex;
        accountBorrowIndex[msg.sender] = borrowIndex;

        totalBorrows += amount;
        SafeTransferLib.safeTransfer(underlying, msg.sender, amount);
        // emit Borrow(...)
    }

    // ===== Repay =====
    function repay(uint256 amount) external nonReentrant {
        accrueInterest();
        require(amount > 0, "repay zero");

        uint userBorrow = borrowBalance(msg.sender);
        require(userBorrow > 0, "no debt");

        SafeTransferLib.safeTransferFrom(underlying, msg.sender, address(this), amount);
        uint repayFinal = amount >= userBorrow ? userBorrow : amount;
        uint newBorrow = userBorrow - repayFinal;

        if (newBorrow == 0) {
            borrowPrincipal[msg.sender] = 0;
            accountBorrowIndex[msg.sender] = borrowIndex;
        } else {
            borrowPrincipal[msg.sender] = newBorrow * 1e18 / borrowIndex;
            accountBorrowIndex[msg.sender] = borrowIndex;
        }

        totalBorrows -= repayFinal;
        // emit Repay(...)
    }

    // ===== Mint / Redeem (adaptar exchangeRate dinámico)
    function exchangeRateCurrent() public returns (uint256) {
        accrueInterest();
        return exchangeRateStored();
    }

    function exchangeRateStored() public view returns (uint256) {
        if (totalSupply == 0) return exchangeRateMantissa; // inicial
        uint cash = IERC20(underlying).balanceOf(address(this));
        uint numerator = cash + totalBorrows - totalReserves;
        return numerator * 1e18 / totalSupply;
    }

    function mint(uint256 amount) external nonReentrant {
        accrueInterest();
        require(amount > 0, "mint zero");
        SafeTransferLib.safeTransferFrom(underlying, msg.sender, address(this), amount);
        uint exRate = exchangeRateStored();
        uint cTokens = amount * 1e18 / exRate;
        totalSupply += cTokens;
        balanceOf[msg.sender] += cTokens;
        // emit Mint(...)
    }

    function redeem(uint256 cTokenAmount) external nonReentrant {
        accrueInterest();
        require(cTokenAmount > 0 && balanceOf[msg.sender] >= cTokenAmount, "redeem invalid");
        uint exRate = exchangeRateStored();
        uint underlyingAmount = cTokenAmount * exRate / 1e18;
        require(comptroller.canRedeem(msg.sender, address(this), cTokenAmount), "unhealthy");
        balanceOf[msg.sender] -= cTokenAmount;
        totalSupply -= cTokenAmount;
        SafeTransferLib.safeTransfer(underlying, msg.sender, underlyingAmount);
        // emit Redeem(...)
    }

    // ===== Admin/Risk =====
    function setReserveFactor(uint256 newFactor) external onlyGuardian {
        require(newFactor <= 0.25e18, "too high");
        uint old = reserveFactorMantissa;
        reserveFactorMantissa = newFactor;
        emit NewReserveFactor(old, newFactor);
    }

    function setInterestRateModel(address newModel) external onlyGuardian {
        IInterestRateModel irm = IInterestRateModel(newModel);
        require(irm.isInterestRateModel(), "bad model");
        address old = address(interestRateModel);
        interestRateModel = irm;
        emit NewInterestRateModel(old, newModel);
    }
}