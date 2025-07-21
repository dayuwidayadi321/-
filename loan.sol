// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@aave/core-v3/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol"; // Import IPoolAddressesProvider

contract AdvancedFlashArbitrage is IFlashLoanSimpleReceiver, Ownable {
    // Gunakan alamat Sepolia untuk contoh ini. Sesuaikan jika Anda di jaringan lain.
    address public constant AAVE_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951; // Aave V3 Pool di Sepolia
    address public constant UNISWAP_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E; // Uniswap V3 Router di Sepolia
    address public constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; // WETH di Sepolia
    
    event FlashLoanInitiated(address asset, uint256 amount);
    event SwapExecuted(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event ArbitrageProfit(address asset, uint256 profit);
    event OperationFailed(bytes reason);

    constructor() Ownable(msg.sender) {}

    // Implementasi fungsi dari IFlashLoanSimpleReceiver
    function ADDRESSES_PROVIDER() external view override returns (IPoolAddressesProvider) {
        // Alamat dummy atau sesuaikan dengan AddressesProvider yang sebenarnya jika Anda menggunakannya
        return IPoolAddressesProvider(0x0000000000000000000000000000000000000000); 
    }

    function POOL() external view override returns (IPool) {
        return IPool(AAVE_POOL); // Mengembalikan alamat pool Aave yang sudah Anda definisikan
    }

    function requestFlashLoan(
        address asset,
        uint256 amount
    ) external onlyOwner {
        IPool(AAVE_POOL).flashLoanSimple(
            address(this),
            asset,
            amount,
            "",
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

        uint256 totalDebt = amount + premium;

        // Coba lakukan arbitrase
        try _advancedArbitrage(asset, amount) returns (uint256 profit) { // Perbaikan di sini: Hapus 'this.'
            // Pastikan kita memiliki cukup token untuk membayar kembali pinjaman
            require(IERC20(asset).balanceOf(address(this)) >= totalDebt, "Not enough funds to repay flash loan");
            
            // Approve AAVE_POOL untuk menarik totalDebt
            IERC20(asset).approve(AAVE_POOL, totalDebt);
            
            emit ArbitrageProfit(asset, profit);
            return true;
        } catch (bytes memory reason) {
            emit OperationFailed(reason);
            // Penting: Pastikan sisa dana yang dipinjam dikembalikan
            // Jika arbitrase gagal, kontrak mungkin masih memiliki sisa dana yang perlu dikembalikan.
            // Di sini kita merevert agar pinjaman dikembalikan secara otomatis oleh Aave.
            revert("Arbitrage failed: " + string(reason));
        }
    }

    function _advancedArbitrage(
        address asset,
        uint256 amount
    ) internal returns (uint256) {
        // Logika arbitrase yang sebenarnya akan lebih kompleks.
        // Ini hanya contoh swap bolak-balik untuk mendemonstrasikan fungsi.
        // Untuk arbitrase nyata, Anda akan mencari perbedaan harga antara DEX/pool yang berbeda.

        // Bagian 1: Swap setengah dari 'asset' ke 'WETH'
        uint256 amountToSwap1 = amount / 2;
        require(IERC20(asset).balanceOf(address(this)) >= amountToSwap1, "Insufficient asset balance for first swap");
        IERC20(asset).approve(UNISWAP_ROUTER, amountToSwap1);
        
        ISwapRouter.ExactInputSingleParams memory params1 = ISwapRouter.ExactInputSingleParams({
            tokenIn: asset,
            tokenOut: WETH,
            fee: 3000, // Fee pool Uniswap V3, contoh 0.3%
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: amountToSwap1,
            amountOutMinimum: 1, // Atur minimum output yang masuk akal
            sqrtPriceLimitX96: 0
        });
        
        uint256 wethAmountOut = ISwapRouter(UNISWAP_ROUTER).exactInputSingle(params1);
        emit SwapExecuted(asset, WETH, amountToSwap1, wethAmountOut);

        // Bagian 2: Swap 'WETH' kembali ke 'asset'
        require(IERC20(WETH).balanceOf(address(this)) >= wethAmountOut, "Insufficient WETH balance for second swap");
        IERC20(WETH).approve(UNISWAP_ROUTER, wethAmountOut);
        
        ISwapRouter.ExactInputSingleParams memory params2 = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: asset,
            fee: 3000, // Fee pool yang sama
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: wethAmountOut,
            amountOutMinimum: 1, // Atur minimum output yang masuk akal
            sqrtPriceLimitX96: 0
        });
        
        uint256 assetAmountOut = ISwapRouter(UNISWAP_ROUTER).exactInputSingle(params2);
        emit SwapExecuted(WETH, asset, wethAmountOut, assetAmountOut);

        // Hitung total asset yang kita miliki setelah swap
        // Ini adalah sisa 'asset' dari pinjaman ditambah hasil swap
        uint256 currentAssetBalance = IERC20(asset).balanceOf(address(this));
        
        // Asumsi keuntungan jika currentAssetBalance lebih besar dari 'amount' awal
        // Sebenarnya, profit harus dihitung dari total_asset_yang_dimiliki - total_utang
        // Dimana total_utang adalah 'amount' + 'premium' dari flash loan.
        // Karena _advancedArbitrage tidak menerima premium, kita akan mengembalikan kelebihan aset.
        // Perhitungan profit sebenarnya akan dilakukan di executeOperation.
        
        return currentAssetBalance - amount; // Mengembalikan keuntungan relatif terhadap jumlah awal yang dipinjam
    }

    function withdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No balance to withdraw");
        IERC20(token).transfer(owner(), balance);
    }

    receive() external payable {}
}
