// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "hardhat/console.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract FlashLoan {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    ISwapRouter constant PANCAKESWAP_V3_ROUTER_ADDRESS = ISwapRouter(0x1b81D678ffb9C0263b24A97847620C99d213eB14);
    ISwapRouter constant UNISWAP_V3_ROUTER_ADDRESS = ISwapRouter(0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2);

    IERC20 private immutable token0;
    IERC20 private immutable token1;
    IUniswapV3Pool public immutable pool;

    address public owner;

    address private constant deployer = 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function.");
        _;
    }

    struct FlashCallBackData {
        uint amount0Borrowed;
        uint amount1Borrowed;
        address caller;

        address tokenInSwap1;
        string symbolInSwap1;
        address tokenOutSwap1;
        string symbolOutSwap1;
        uint24 feeSwap1;
        uint8 exchangeSwap1;
        uint amountOutMinSwap1;

        address tokenInSwap2;
        string symbolInSwap2;
        address tokenOutSwap2;
        string symbolOutSwap2;
        uint24 feeSwap2;
        uint8 exchangeSwap2;
        uint amountOutMinSwap2;
    }

    struct SwapParams {
        address tokenIn;
        string symbolIn;
        address tokenOut;
        string symbolOut;
        uint24 fee;
        uint8 exchange;
        uint amountOutMin;
    }

    constructor(address _token0, address _token1, uint24 _fee) {
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        pool = IUniswapV3Pool(getPool(_token0, _token1, _fee));
        console.log("FlashLoan Pool Address set to:", address(pool));
        owner = msg.sender;
    }

    function getPool(address _token0,address _token1,uint24 _fee) public pure returns (address){
        PoolAdress.PoolKey memory poolKey = PoolAdress.getPoolKey(_token0, _token1, _fee);
        return PoolAdress.computeAddress(deployer, poolKey);
    }

    event FundsAdded(address indexed sender, uint amount);

    function add() public  payable {
        require(msg.value > 0, "Send some ether");
        emit FundsAdded(msg.sender, msg.value);
    }

    function flashLoanRequest(
        uint256 _amount0ToBorrow,
        uint256 _amount1ToBorrow,
        SwapParams memory _swap1Params, 
        SwapParams memory _swap2Params
    ) external {
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
        IUniswapV3Pool(pool).flash(address(this), _amount0ToBorrow, _amount1ToBorrow, data);
    }

    function pancakeV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external {
        require(msg.sender == address(pool), "not authorized");

        FlashCallBackData memory decoded = abi.decode(data, (FlashCallBackData));

        IERC20 borrowedToken;
        uint256 acquiredAmount;

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

        console.log("Executing Swap 2:");
        console.log("Amount In:", amountOutSwap1);
        console.log("From Token:", decoded.tokenInSwap2);
        console.log("To Token:", decoded.tokenOutSwap2);

        uint256 finalAmountOfBorrowedToken = _place_swap_v3(
            amountOutSwap1,
            decoded.tokenInSwap2,
            decoded.tokenOutSwap2,
            decoded.feeSwap2,
            decoded.exchangeSwap2,
            decoded.amountOutMinSwap2
        );
        console.log("Swap 2 resulted in (borrowed token):", finalAmountOfBorrowedToken, decoded.symbolOutSwap2);

        uint256 amountToRepay;
        if (decoded.amount0Borrowed > 0) {
            amountToRepay = decoded.amount0Borrowed + fee0;
            console.log("Repaying Token0.");
            console.log("Loaned:", decoded.amount0Borrowed);
            console.log("Fee:", fee0, "Total:", amountToRepay);
        } else {
            amountToRepay = decoded.amount1Borrowed + fee1;
            console.log("Repaying Token1. Loaned:", decoded.amount1Borrowed);
            console.log("Fee:", fee1, "Total:", amountToRepay);
        }

        require(finalAmountOfBorrowedToken >= amountToRepay, "Insufficient funds to repay flash loan");

        borrowedToken.safeTransfer(address(pool), amountToRepay);

        uint256 remainingBalance = borrowedToken.balanceOf(address(this));
        if (remainingBalance > 0) {
            console.log("Sending profit to caller:", remainingBalance, "of", address(borrowedToken));
            borrowedToken.safeTransfer(decoded.caller, remainingBalance);
        }
    }

    function _place_swap_v3(
        uint256 _amountIn,
        address _tokenIn,
        address _tokenOut,
        uint24 _fee,
        uint8 _exchange,
        uint256 _amountOutMinimum
    ) private returns (uint256) {
        uint deadline = block.timestamp + 30;

        ISwapRouter targetRouter;
        if (_exchange == 0) {
            targetRouter = PANCAKESWAP_V3_ROUTER_ADDRESS;
            console.log("Swapping on PancakeSwap V3 Router:", address(targetRouter));
        } else if (_exchange == 1) {
            targetRouter = UNISWAP_V3_ROUTER_ADDRESS;
            console.log("Swapping on Uniswap V3 Router:", address(targetRouter));
        } else {
            revert("Invalid exchange specified for swap (must be 0 or 1)");
        }

        TransferHelper.safeApprove(_tokenIn, address(targetRouter), _amountIn);
        console.log("Approved router to spend:", _amountIn, "of", _tokenIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: _fee,
            recipient: address(this),
            deadline: deadline,
            amountIn: _amountIn,
            amountOutMinimum: _amountOutMinimum,
            sqrtPriceLimitX96: 0
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

library PoolAdress {
    bytes32 internal constant POOL_INIT_CODE_HASH =
        0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2;

    struct PoolKey {
        address token0;
        address token1;
        uint24 fee;
    }

    function getPoolKey(
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal pure returns (PoolKey memory) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey({token0: tokenA, token1: tokenB, fee: fee});
    }

    function computeAddress(
        address deployer,
        PoolKey memory key
    ) internal pure returns (address pool) {
        require(key.token0 < key.token1, "PoolAdress: TOKEN_ORDER");
        pool = address(
            uint160(
                uint(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            deployer,
                            keccak256(abi.encode(key.token0, key.token1, key.fee)),
                            POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }
}
