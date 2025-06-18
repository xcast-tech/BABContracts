// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./interfaces/IWETH.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UniswapTest {

  address WETH;
  address swapRouter;

  constructor(address _WETH, address _swapRouter) {
    WETH = _WETH;
    swapRouter = _swapRouter;
  }

  function approve(address token, address spender, uint256 amount) public {
    IERC20(token).approve(spender, amount);
  }

  function testUniswapBuy(address token, address recipient, uint256 minOrderSize, uint160 sqrtPriceLimitX96) public payable {
    IWETH(WETH).deposit{value: msg.value}();
    IWETH(WETH).approve(swapRouter, msg.value);

    ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
      tokenIn: WETH,
      tokenOut: token,
      fee: 2500,
      recipient: recipient,
      deadline: 99999999999999,
      amountIn: msg.value,
      amountOutMinimum: minOrderSize,
      sqrtPriceLimitX96: sqrtPriceLimitX96
    });

    ISwapRouter(swapRouter).exactInputSingle(params);
  }

  function testUniswapSell(address token, uint256 tokensToSell, address recipient, uint256 minOrderSize, uint160 sqrtPriceLimitX96) public payable {
    IERC20(token).approve(swapRouter, tokensToSell);
    
    ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
      tokenIn: token,
      tokenOut: WETH,
      fee: 2500,
      recipient: recipient,
      deadline: 99999999999999,
      amountIn: tokensToSell,
      amountOutMinimum: minOrderSize,
      sqrtPriceLimitX96: sqrtPriceLimitX96
    });

    ISwapRouter(swapRouter).exactInputSingle(params);
  }

  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {}

}