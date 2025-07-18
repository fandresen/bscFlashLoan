// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Imports
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title FlashLoan
 * @author Votre Nom
 * @notice Contrat d'arbitrage via flash loan, optimisé pour une exécution directe
 * via un RPC privé afin de prévenir le front-running.
 */
contract FlashLoan is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Erreurs personnalisées ---
    error NotOwner();
    error NotPool();
    error InvalidExchange();
    error InsufficientFundsToRepay();
    error NoProfitToSend();
    error NoFundsToWithdraw();
    error NoAmountBorrowed();

    // --- Constantes et Variables d'état ---
    ISwapRouter public immutable PANCAKESWAP_V3_ROUTER;
    ISwapRouter public immutable UNISWAP_V3_ROUTER;
    address public immutable V3_FACTORY;
    IERC20 private immutable token0;
    IERC20 private immutable token1;
    IUniswapV3Pool public immutable pool;
    address public immutable owner;

    // --- Structures de données ---

    // Paramètres de swap
    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint8 exchange; // 0 for Pancake, 1 for Uniswap
        uint amountOutMin;
    }

    // Données passées au callback du flash loan
    struct FlashCallbackData {
        uint256 amount0Borrowed;
        uint256 amount1Borrowed;
        address profitRecipient;
        SwapParams swap1Params;
        SwapParams swap2Params;
    }

    // --- Modificateur ---
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // --- Constructeur ---
    constructor(
        address _token0,
        address _token1,
        uint24 _poolFee,
        address _v3Factory,
        address _pancakeRouter,
        address _uniswapRouter
    ) {
        owner = msg.sender;
        V3_FACTORY = _v3Factory;
        PANCAKESWAP_V3_ROUTER = ISwapRouter(_pancakeRouter);
        UNISWAP_V3_ROUTER = ISwapRouter(_uniswapRouter);
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        pool = IUniswapV3Pool(PoolAddress.getPool(_v3Factory, _token0, _token1, _poolFee));
    }

    // --- Logique d'Arbitrage ---

    /**
     * @notice Point d'entrée pour le bot. Déclenche l'arbitrage.
     * @dev Uniquement l'owner (le bot) peut appeler cette fonction.
     * @param _amount0ToBorrow Montant de token0 à emprunter.
     * @param _amount1ToBorrow Montant de token1 à emprunter.
     * @param _swap1Params Paramètres du premier swap.
     * @param _swap2Params Paramètres du second swap.
     */
    function executeArbitrage(
        uint256 _amount0ToBorrow,
        uint256 _amount1ToBorrow,
        SwapParams memory _swap1Params,
        SwapParams memory _swap2Params
    ) external onlyOwner nonReentrant {
        // Le profit sera envoyé à l'owner du contrat.
        _initiateFlashLoan(
            _amount0ToBorrow,
            _amount1ToBorrow,
            _swap1Params,
            _swap2Params,
            owner
        );
    }

    /**
     * @notice Exécute la logique de flash loan.
     */
    function _initiateFlashLoan(
        uint256 _amount0ToBorrow,
        uint256 _amount1ToBorrow,
        SwapParams memory _swap1Params,
        SwapParams memory _swap2Params,
        address _profitRecipient
    ) internal {
        bytes memory data = abi.encode(FlashCallbackData({
            amount0Borrowed: _amount0ToBorrow,
            amount1Borrowed: _amount1ToBorrow,
            profitRecipient: _profitRecipient,
            swap1Params: _swap1Params,
            swap2Params: _swap2Params
        }));
        
        pool.flash(address(this), _amount0ToBorrow, _amount1ToBorrow, data);
    }

    /**
     * @notice Callback pour le flash loan Uniswap V3. Ce nom est standard.
     */
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external nonReentrant {
        if (msg.sender != address(pool)) revert NotPool();

        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));

        uint256 amountToRepay;
        uint256 borrowedAmount;
        IERC20 borrowedToken;

        if (decoded.amount0Borrowed > 0) {
            borrowedAmount = decoded.amount0Borrowed;
            borrowedToken = token0;
            amountToRepay = borrowedAmount + fee0;
        } else if (decoded.amount1Borrowed > 0) {
            borrowedAmount = decoded.amount1Borrowed;
            borrowedToken = token1;
            amountToRepay = borrowedAmount + fee1;
        } else {
            revert NoAmountBorrowed();
        }

        // --- Exécution des Swaps ---
        uint256 amountOutSwap1 = _place_swap_v3(borrowedAmount, decoded.swap1Params);
        uint256 finalAmountOfBorrowedToken = _place_swap_v3(amountOutSwap1, decoded.swap2Params);

        // --- Remboursement et Profit ---
        if (finalAmountOfBorrowedToken < amountToRepay) revert InsufficientFundsToRepay();

        // 1. Rembourser le prêt + les frais
        borrowedToken.safeTransfer(address(pool), amountToRepay);

        // 2. Envoyer le profit au bénéficiaire (l'owner)
        uint256 profit = finalAmountOfBorrowedToken - amountToRepay;
        if (profit > 0) {
            borrowedToken.safeTransfer(decoded.profitRecipient, profit);
        }
    }

    function _place_swap_v3(
        uint256 _amountIn,
        SwapParams memory _params
    ) private returns (uint256) {
        ISwapRouter targetRouter;
        if (_params.exchange == 0) { // 0 pour PancakeSwap
            targetRouter = PANCAKESWAP_V3_ROUTER;
        } else if (_params.exchange == 1) { // 1 pour Uniswap
            targetRouter = UNISWAP_V3_ROUTER;
        } else {
            revert InvalidExchange();
        }

        IERC20(_params.tokenIn).approve(address(targetRouter), _amountIn);

        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: _params.tokenIn,
            tokenOut: _params.tokenOut,
            fee: _params.fee,
            recipient: address(this),
            deadline: block.timestamp + 12, // Le MEV étant géré par un RPC privé, un délai court est acceptable.
            amountIn: _amountIn,
            amountOutMinimum: _params.amountOutMin,
            sqrtPriceLimitX96: 0
        });

        return targetRouter.exactInputSingle(swapParams);
    }

    // --- Fonctions Utilitaires ---
    /**
     * @notice Permet au propriétaire de retirer des tokens ERC20 envoyés par erreur au contrat.
     */
    function withdrawStuckFunds(address _tokenAddress) external onlyOwner {
        IERC20 token = IERC20(_tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NoFundsToWithdraw();
        token.safeTransfer(owner, balance);
    }

    /**
     * @notice Permet de recevoir du BNB/ETH natif si nécessaire.
     */
    receive() external payable {}
}


// --- Bibliothèque pour calculer l'adresse de la pool (inchangée) ---
library PoolAddress {
    bytes32 internal constant POOL_INIT_CODE_HASH = 0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2;

    struct PoolKey {
        address token0;
        address token1;
        uint24 fee;
    }

    function getPoolKey(address tokenA, address tokenB, uint24 fee) internal pure returns (PoolKey memory) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey({token0: tokenA, token1: tokenB, fee: fee});
    }

    function getPool(address _factory, address _token0, address _token1, uint24 _fee) internal pure returns (address) {
        PoolKey memory poolKey = getPoolKey(_token0, _token1, _fee);
        return computeAddress(_factory, poolKey);
    }

    function computeAddress(address factory, PoolKey memory key) internal pure returns (address pool) {
        pool = address(uint160(uint(keccak256(abi.encodePacked(
            hex"ff",
            factory,
            keccak256(abi.encode(key.token0, key.token1, key.fee)),
            POOL_INIT_CODE_HASH
        )))));
    }
}