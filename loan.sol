// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@aave/core-v3/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

interface IPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint256 referralCode
    ) external;
}

contract AdvancedFlashArbitrage is IFlashLoanSimpleReceiver, Ownable {
    address public constant AAVE_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address public constant UNISWAP_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address public constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    
    event FlashLoanInitiated(address asset, uint256 amount);
    event SwapExecuted(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event ArbitrageProfit(address asset, uint256 profit);
    event OperationFailed(bytes reason);

    constructor() Ownable(msg.sender) {}

    function requestFlashLoan(
        address asset,
        uint256 amount,
        bytes memory dexData
    ) external onlyOwner {
        IPool(AAVE_POOL).flashLoanSimple(
            address(this),
            asset,
            amount,
            dexData,
            0
        );
        emit FlashLoanInitiated(asset, amount);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == AAVE_POOL, "Invalid caller");
        require(initiator == address(this), "Invalid initiator");

        try this._advancedArbitrage(asset, amount, premium, params) returns (uint256 profit) {
            uint256 totalDebt = amount + premium;
            IERC20(asset).approve(AAVE_POOL, totalDebt);
            
            emit ArbitrageProfit(asset, profit);
            return true;
        } catch (bytes memory reason) {
            emit OperationFailed(reason);
            revert("Arbitrage failed");
        }
    }

    function _advancedArbitrage(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata dexData
    ) external returns (uint256) {
        IERC20(asset).approve(UNISWAP_ROUTER, amount);
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: asset,
            tokenOut: WETH,
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: amount / 2,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        
        uint256 wethAmount = ISwapRouter(UNISWAP_ROUTER).exactInputSingle(params);
        emit SwapExecuted(asset, WETH, amount / 2, wethAmount);

        IERC20(WETH).approve(UNISWAP_ROUTER, wethAmount);
        
        ISwapRouter.ExactInputSingleParams memory reverseParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: asset,
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: wethAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        
        uint256 assetAmountOut = ISwapRouter(UNISWAP_ROUTER).exactInputSingle(reverseParams);
        emit SwapExecuted(WETH, asset, wethAmount, assetAmountOut);

        uint256 totalAsset = assetAmountOut + (amount / 2);
        uint256 totalDebt = amount + premium;
        
        require(totalAsset > totalDebt, "No profit opportunity");
        uint256 profit = totalAsset - totalDebt;
        
        return profit;
    }

    function withdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(owner(), balance);
    }

    receive() external payable {}
}
