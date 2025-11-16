// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../interfaces/IV_MasterEnhanced.sol";
import "../interfaces/IVibePriceOracle.sol";
import "../libraries/SafeTransferLib.sol";

interface IERC20Decimals { function decimals() external view returns (uint8); }

contract V_cERC20_Extended {
    string public name;
    string public symbol;
    uint8 public decimals;

    address public immutable underlying;
    IV_MasterEnhanced public immutable comptroller;
    address public guardian;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public borrowBalance;

    uint256 public exchangeRateMantissa = 1e18;

    uint8 private _status;
    uint8 private constant _NOT_ENTERED = 1;
    uint8 private constant _ENTERED = 2;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Mint(address indexed minter, uint256 underlyingAmount, uint256 cTokensMinted);
    event Redeem(address indexed redeemer, uint256 underlyingAmount, uint256 cTokensBurned);
    event Borrow(address indexed borrower, uint256 amount);
    event Repay(address indexed payer, address indexed borrower, uint256 amount);
    event LiquidateBorrow(address indexed liquidator, address indexed borrower, uint256 repayAmount, address cTokenCollateral, uint256 seizeTokens);
    event GuardianSet(address indexed guardian);

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

    constructor(string memory _n, string memory _s, address _underlying, address _comptroller, address _guardian) {
        name = _n;
        symbol = _s;
        decimals = 18;
        underlying = _underlying;
        comptroller = IV_MasterEnhanced(_comptroller);
        require(comptroller.isComptroller(), "invalid comptroller");
        guardian = _guardian;
        _status = _NOT_ENTERED;
        emit GuardianSet(_guardian);
    }

    function setGuardian(address g) external onlyGuardian {
        guardian = g;
        emit GuardianSet(g);
    }

    function underlyingAddress() external view returns (address) { return underlying; }
    function underlyingDecimals() external view returns (uint8) { return IERC20Decimals(underlying).decimals(); }
    function exchangeRateStored() external view returns (uint256) { return exchangeRateMantissa; }
    function borrowBalanceStored(address owner) external view returns (uint256) { return borrowBalance[owner]; }

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

    function mint(uint256 amount) external nonReentrant {
        require(amount > 0, "mint zero");
        SafeTransferLib.safeTransferFrom(underlying, msg.sender, address(this), amount);

        uint8 ud = IERC20Decimals(underlying).decimals();
        uint256 adjusted = amount;
        if (ud < 18) adjusted = amount * (10 ** (18 - ud));
        else if (ud > 18) adjusted = amount / (10 ** (ud - 18));

        uint256 cTokens = (adjusted * 1e18) / exchangeRateMantissa;
        balanceOf[msg.sender] += cTokens;
        totalSupply += cTokens;

        emit Mint(msg.sender, amount, cTokens);
        emit Transfer(address(0), msg.sender, cTokens);
    }

    function redeem(uint256 cTokenAmount) external nonReentrant {
        require(cTokenAmount > 0 && balanceOf[msg.sender] >= cTokenAmount, "redeem invalid");
        require(comptroller.canRedeem(msg.sender, address(this), cTokenAmount), "unhealthy after redeem");

        uint256 underlyingScaled = (cTokenAmount * exchangeRateMantissa) / 1e18;
        uint8 ud = IERC20Decimals(underlying).decimals();
        uint256 underlyingToTransfer = underlyingScaled;
        if (ud < 18) underlyingToTransfer = underlyingScaled / (10 ** (18 - ud));
        else if (ud > 18) underlyingToTransfer = underlyingScaled * (10 ** (ud - 18));

        balanceOf[msg.sender] -= cTokenAmount;
        totalSupply -= cTokenAmount;
        SafeTransferLib.safeTransfer(underlying, msg.sender, underlyingToTransfer);

        emit Redeem(msg.sender, underlyingToTransfer, cTokenAmount);
        emit Transfer(msg.sender, address(0), cTokenAmount);
    }

    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, "borrow zero");
        require(comptroller.canBorrow(msg.sender, address(this), amount), "insufficient collateral");
        borrowBalance[msg.sender] += amount;
        SafeTransferLib.safeTransfer(underlying, msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        require(amount > 0, "repay zero");
        SafeTransferLib.safeTransferFrom(underlying, msg.sender, address(this), amount);
        uint256 debt = borrowBalance[msg.sender];
        require(debt > 0, "no debt");
        uint256 paid = amount >= debt ? debt : amount;
        borrowBalance[msg.sender] = amount >= debt ? 0 : debt - amount;
        emit Repay(msg.sender, msg.sender, paid);
    }

    function liquidateBorrow(address borrower, uint256 repayAmount, address cTokenCollateral) external nonReentrant {
        require(borrower != msg.sender, "self liquidate");
        uint256 borrowerDebtPrev = borrowBalance[borrower];
        require(borrowerDebtPrev > 0, "no debt");

        require(
            comptroller.seizeAllowed(borrower, msg.sender, cTokenCollateral, address(this), 0),
            "not liquidatable"
        );

        uint256 cf = comptroller.closeFactorMantissa();
        uint256 maxRepay = (borrowerDebtPrev * cf + 1e18 - 1) / 1e18;
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
                V_cERC20_Extended(cTokenCollateral).balanceOf(borrower) >= seizeCTokens,
                "insufficient collateral tokens"
            );
        }

        SafeTransferLib.safeTransferFrom(underlying, msg.sender, address(this), repayAmount);

        if (cTokenCollateral == address(this)) {
            _seizeInternal(msg.sender, borrower, seizeCTokens);
        } else {
            V_cERC20_Extended(cTokenCollateral).seize(msg.sender, borrower, seizeCTokens);
        }

        borrowBalance[borrower] = borrowerDebtPrev - repayAmount;

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

    function previewSeizeTokens(address cTokenCollateral, uint256 repayAmount) external view returns (uint256) {
        return _computeSeizeCTokens(cTokenCollateral, repayAmount);
    }

    function _computeSeizeCTokens(address cTokenCollateral, uint256 repayAmount) internal view returns (uint256) {
        IVibePriceOracle o = IVibePriceOracle(comptroller.oracle());
        uint256 priceBorrowed = o.getUnderlyingPrice(address(this));
        require(priceBorrowed > 0, "oracle borrowed");
        uint256 priceCollateral = o.getUnderlyingPrice(cTokenCollateral);
        require(priceCollateral > 0, "oracle collateral");

        uint8 decBorrow = IERC20Decimals(underlying).decimals();
        uint256 repayUSD = (repayAmount * priceBorrowed) / (10 ** decBorrow);

        uint256 incentive = comptroller.liquidationIncentiveMantissa();
        require(incentive >= 1e18, "bad incentive");
        uint256 seizeUSD = (repayUSD * incentive) / 1e18;

        address uCol = V_cERC20_Extended(cTokenCollateral).underlyingAddress();
        uint8 decCol = IERC20Decimals(uCol).decimals();
        uint256 seizeUnderlyingRaw = (seizeUSD * (10 ** decCol)) / priceCollateral;

        uint256 normalized;
        if (decCol < 18) normalized = seizeUnderlyingRaw * (10 ** (18 - decCol));
        else if (decCol > 18) normalized = seizeUnderlyingRaw / (10 ** (decCol - 18));
        else normalized = seizeUnderlyingRaw;

        uint256 exRateCol = V_cERC20_Extended(cTokenCollateral).exchangeRateStored();
        return (normalized * 1e18) / exRateCol;
    }
}