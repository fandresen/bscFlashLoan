// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "hardhat/console.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title FlashLoan
 * @dev Contrat pour exécuter un arbitrage Flash Loan entre deux exchanges Uniswap V3.
 * Le Flash Loan est pris depuis une pool Uniswap V3.
 */
contract FlashLoan {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Adresses des routeurs Uniswap V3 sur BSC Mainnet
    // Assurez-vous que ces adresses sont correctes pour votre déploiement.
    ISwapRouter constant PANCAKESWAP_V3_ROUTER_ADDRESS = ISwapRouter(0x1b81D678ffb9C0263b24A97847620C99d213eB14); // Router de PancakeSwap V3
    ISwapRouter constant UNISWAP_V3_ROUTER_ADDRESS = ISwapRouter(0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2); // Router de Uniswap V3

    IERC20 private immutable token0; // Token 0 de la pool de Flash Loan
    IERC20 private immutable token1; // Token 1 de la pool de Flash Loan
    IUniswapV3Pool public immutable pool; // Pool Uniswap V3 d'où le Flash Loan est pris

    address public owner; 

    modifier onlyOwner() {
    require(msg.sender == owner, "Only owner can call this function.");
        _;
    }

    // Structure pour les données passées au callback du Flash Loan
    struct FlashCallBackData {
        uint amount0Borrowed; // Montant de token0 emprunté de la pool de Flash Loan
        uint amount1Borrowed; // Montant de token1 emprunté de la pool de Flash Loan
        address caller; // Adresse qui a initié la requête de Flash Loan

        // Détails pour le Swap 1 (e.g., Token A -> Token B)
        address tokenInSwap1; // Adresse du token d'entrée pour le Swap 1
        string symbolInSwap1; //Symbol du token d'entrée pour le Swap 1
        address tokenOutSwap1; // Adresse du token de sortie pour le Swap 1
        string symbolOutSwap1; //Symbol du token de sortie pour le Swap 1
        uint24 feeSwap1; // Niveau de frais V3 pour le Swap 1
        uint8 exchangeSwap1; // 0: PancakeSwap V3, 1: Uniswap V3
        uint amountOutMinSwap1; // Montant minimum de sortie attendu pour le Swap 1 (contrôle du slippage)

        // Détails pour le Swap 2 (e.g., Token B -> Token A, pour le remboursement)
        address tokenInSwap2; // Adresse du token d'entrée pour le Swap 2
        string symbolInSwap2; //Symbol du token d'entrée pour le Swap 2
        address tokenOutSwap2; // Adresse du token de sortie pour le Swap 2
        string symbolOutSwap2; //Symbol du token de sortir pour le Swap 2
        uint24 feeSwap2; // Niveau de frais V3 pour le Swap 2
        uint8 exchangeSwap2; // 0: PancakeSwap V3, 1: Uniswap V3
        uint amountOutMinSwap2; // Montant minimum de sortie attendu pour le Swap 2 (contrôle du slippage)
    }

     //STRUCTURE POUR LES PARAMÈTRES DE SWAP
    struct SwapParams {
        address tokenIn;
        string symbolIn;
        address tokenOut;
        string symbolOut;
        uint24 fee;
        uint8 exchange; // 0: PancakeSwap V3, 1: Uniswap V3
        uint amountOutMin;
    }

    constructor(address _token0, address _token1, uint24 _fee, address _factoryAddress) {
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        // Calcule l'adresse de la pool V3 à partir de la factory et des tokens/frais.
        pool = IUniswapV3Pool(PoolAdress.computeAddress(_factoryAddress, PoolAdress.getPoolKey(_token0, _token1, _fee)));
        console.log("FlashLoan Pool Address set to:", address(pool));
    }

    function flashLoanRequest(
        uint256 _amount0ToBorrow,
        uint256 _amount1ToBorrow,
        SwapParams memory _swap1Params, 
        SwapParams memory _swap2Params
    ) external {
            // Encode toutes les données nécessaires pour le callback
    bytes memory data = abi.encode(FlashCallBackData({
            amount0Borrowed: _amount0ToBorrow,
            amount1Borrowed: _amount1ToBorrow,
            caller: msg.sender,
            tokenInSwap1: _swap1Params.tokenIn,
            symbolInSwap1: _swap1Params.symbolIn,
            tokenOutSwap1: _swap1Params.tokenOut,
            symbolOutSwap1: _swap1Params.symbolOut,
            feeSwap1: _swap1Params.fee,
            exchangeSwap1: _swap1Params.exchange,
            amountOutMinSwap1: _swap1Params.amountOutMin,
            tokenInSwap2: _swap2Params.tokenIn,
            symbolInSwap2: _swap2Params.symbolIn,
            tokenOutSwap2: _swap2Params.tokenOut,
            symbolOutSwap2: _swap2Params.symbolOut,
            feeSwap2: _swap2Params.fee,
            exchangeSwap2: _swap2Params.exchange,
            amountOutMinSwap2: _swap2Params.amountOutMin
        }));

        console.log("Initiating Flash Loan from pool:", address(pool));
        // Lance le Flash Loan depuis la pool V3. Le callback pancakeV3FlashCallback sera appelé.
        IUniswapV3Pool(pool).flash(address(this), _amount0ToBorrow, _amount1ToBorrow, data);
    }

    function pancakeV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external {
        // S'assure que seul la pool de Flash Loan peut appeler cette fonction.
        require(msg.sender == address(pool), "not authorized");

        // Décode les données passées au callback.
        FlashCallBackData memory decoded = abi.decode(data, (FlashCallBackData));

        IERC20 borrowedToken; // Le token qui a été emprunté
        uint256 acquiredAmount; // Le montant du token emprunté initialement reçu

        // Détermine quel token a été emprunté de la pool de Flash Loan
        if (decoded.amount0Borrowed > 0) {
            borrowedToken = token0;
            acquiredAmount = decoded.amount0Borrowed;
            console.log("Borrowed Token0:", address(token0), "Amount:", acquiredAmount);
        } else if (decoded.amount1Borrowed > 0) {
            borrowedToken = token1;
            acquiredAmount = decoded.amount1Borrowed;
            console.log("Borrowed Token1:", address(token1), "Amount:", acquiredAmount);
        } else {
            revert("No amount specified for borrowing");
        }

        // SWAP 1: Du token emprunté vers le token intermédiaire (ex: WBNB -> USDT)
        console.log("Executing Swap 1:");
        console.log("Amount In:", acquiredAmount);
        console.log("From Token:", decoded.tokenInSwap1);
        console.log("To Token:", decoded.tokenOutSwap1);

        uint256 amountOutSwap1 = _place_swap_v3(
            acquiredAmount,
            decoded.tokenInSwap1,
            decoded.tokenOutSwap1,
            decoded.feeSwap1,
            decoded.exchangeSwap1,
            decoded.amountOutMinSwap1
        );
        console.log("Swap 1 resulted in:", amountOutSwap1, decoded.symbolOutSwap1);


        // SWAP 2: Du token intermédiaire vers le token emprunté (ex: USDT -> WBNB) pour rembourser le prêt
        console.log("Executing Swap 2:");
        console.log("Amount In:", amountOutSwap1);
        console.log("From Token:", decoded.tokenInSwap2);
        console.log("To Token:", decoded.tokenOutSwap2);

        uint256 finalAmountOfBorrowedToken = _place_swap_v3(
            amountOutSwap1, // L'entrée du swap 2 est la sortie du swap 1
            decoded.tokenInSwap2,
            decoded.tokenOutSwap2,
            decoded.feeSwap2,
            decoded.exchangeSwap2,
            decoded.amountOutMinSwap2
        );
        console.log("Swap 2 resulted in (borrowed token):", finalAmountOfBorrowedToken, decoded.symbolOutSwap2);


        // REMBOURSEMENT DU FLASH LOAN
        uint256 amountToRepay;
        if (decoded.amount0Borrowed > 0) {
            amountToRepay = decoded.amount0Borrowed + fee0;
            console.log("Repaying Token0.");
            console.log("Loaned:", decoded.amount0Borrowed);
            console.log("Fee:", fee0, "Total:", amountToRepay);
        } else { // decoded.amount1Borrowed > 0
            amountToRepay = decoded.amount1Borrowed + fee1;
            console.log("Repaying Token1. Loaned:", decoded.amount1Borrowed);
            console.log("Fee:", fee1, "Total:", amountToRepay);
        }

        // S'assure que le contrat a suffisamment du token emprunté pour rembourser
        require(finalAmountOfBorrowedToken >= amountToRepay, "Insufficient funds to repay flash loan");

        // Approuve la pool à prendre le montant du remboursement
        // La pool prendra les tokens directement du contrat d'arbitrage.
        // On n'a pas besoin d'approuver 'this' si on utilise safeTransfer de 'this' vers la pool.
        // TransferHelper.safeApprove(address(borrowedToken), address(this), amountToRepay); // Ce n'est pas correct pour le remboursement à la pool
        borrowedToken.safeTransfer(address(pool), amountToRepay); // Transfère directement à la pool

        // Envoie le profit restant (s'il y en a) à l'appelant original
        uint256 remainingBalance = borrowedToken.balanceOf(address(this));
        if (remainingBalance > 0) {
            console.log("Sending profit to caller:", remainingBalance, "of", address(borrowedToken));
            borrowedToken.safeTransfer(decoded.caller, remainingBalance);
        }
    }

    /**
     * @dev Exécute un swap unique sur un routeur Uniswap V3 spécifié.
     * @param _amountIn Montant du token d'entrée.
     * @param _tokenIn Adresse du token d'entrée.
     * @param _tokenOut Adresse du token de sortie.
     * @param _fee Niveau de frais de la pool V3.
     * @param _exchange Type d'exchange (0: PancakeSwap V3, 1: Uniswap V3).
     * @param _amountOutMinimum Montant minimum de sortie pour le swap (contrôle du slippage).
     * @return Le montant de sortie du swap.
     */
    function _place_swap_v3(
        uint256 _amountIn,
        address _tokenIn,
        address _tokenOut,
        uint24 _fee,
        uint8 _exchange,
        uint256 _amountOutMinimum
    ) private returns (uint256) {
        uint deadline = block.timestamp + 30; // Deadline pour la transaction

        ISwapRouter targetRouter;
        if (_exchange == 0) { // PancakeSwap V3
            targetRouter = PANCAKESWAP_V3_ROUTER_ADDRESS;
            console.log("Swapping on PancakeSwap V3 Router:", address(targetRouter));
        } else if (_exchange == 1) { // Uniswap V3
            targetRouter = UNISWAP_V3_ROUTER_ADDRESS;
            console.log("Swapping on Uniswap V3 Router:", address(targetRouter));
        } else {
            revert("Invalid exchange specified for swap (must be 0 or 1)");
        }

        // Approuve le routeur à dépenser les tokens d'entrée
        TransferHelper.safeApprove(_tokenIn, address(targetRouter), _amountIn);
        console.log("Approved router to spend:", _amountIn, "of", _tokenIn);


        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                fee: _fee,
                recipient: address(this), // Le token de sortie est envoyé à ce contrat
                deadline: deadline,
                amountIn: _amountIn,
                amountOutMinimum: _amountOutMinimum, // Contrôle du slippage
                sqrtPriceLimitX96: 0 // Pas de limite de prix spécifique
            });

        uint256 swap_amount_out = targetRouter.exactInputSingle(params);
        console.log("Swap completed. Output:", swap_amount_out, _tokenOut);
        return swap_amount_out;
    }


    function withdrawStuckFunds(address _tokenAddress) external onlyOwner {
        IERC20 token = IERC20(_tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0,"No balance to recover");
        token.safeTransfer(owner, balance);
  
    }
}

/**
 * @title PoolAdress
 * @dev Librairie pour calculer déterministement les adresses de pool Uniswap V3.
 * Utilisé pour trouver l'adresse de la pool pour le Flash Loan.
 */
library PoolAdress {
    // Le hash du bytecode d'initialisation spécifique aux pools Uniswap V3 (et PancakeSwap V3).
    bytes32 internal constant POOL_INIT_CODE_HASH =
        0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2; // Hash pour PancakeSwap V3 sur BSC

    // L'adresse de la factory Uniswap V3 où la pool du flash loan a été créée.
    // Pour PancakeSwap V3 Factory sur BSC Mainnet : 0x0BFbCf9fa4fC56b3eF40d646c56b0256dac3B474
    // Assurez-vous que cette adresse est correcte pour la factory de la pool où vous prenez le flash loan.
    // Cette constante n'est plus utilisée directement ici, mais le pattern est conservé.
    // L'adresse de la factory est maintenant passée au constructeur du contrat FlashLoan.

    struct PoolKey {
        address token0;
        address token1;
        uint24 fee;
    }

    /**
     * @dev Génère la clé de pool canonique pour deux tokens et un niveau de frais.
     * @param tokenA Adresse du premier token.
     * @param tokenB Adresse du deuxième token.
     * @param fee Niveau de frais de la pool.
     * @return La clé de pool canonique.
     */
    function getPoolKey(
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal pure returns (PoolKey memory) {
        // Assure que token0 < token1 pour la canonisation
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey({token0: tokenA, token1: tokenB, fee: fee});
    }


    function computeAddress(
        address factory, // Maintenant passé en paramètre
        PoolKey memory key
    ) internal pure returns (address pool) {
        require(key.token0 < key.token1, "PoolAdress: TOKEN_ORDER"); // Assure l'ordre canonique
        pool = address(
            uint160(
                uint(
                    keccak256(
                        abi.encodePacked(
                            hex"ff", // Préfixe pour le calcul d'adresse de contrat CREATE2
                            factory, // Adresse de la factory
                            keccak256(abi.encode(key.token0, key.token1, key.fee)), // Hash des arguments de construction
                            POOL_INIT_CODE_HASH // Hash du bytecode d'initialisation de la pool
                        )
                    )
                )
            )
        );
    }
}