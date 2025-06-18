// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/IPancakeswapV3Pool.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IBABFactory.sol";
import "./interfaces/IBABValidator.sol";
import "./interfaces/IBondingCurve.sol";

contract BAB is ERC20, IERC721Receiver, ReentrancyGuard {

  error NotGraduate();
  error ValidationFail();
  error EthAmountTooSmall();
  error AddressZero();
  error EthTransferFailed();
  error InsufficientToken();
  error SlippageBoundsExceeded();
  error OnlyPool();

  struct SecondaryRewards {
    uint256 totalAmountEth;
    uint256 totalAmountToken;
    uint256 creatorAmountEth;
    uint256 creatorAmountToken;
  }

  event BABTokenBuy(address indexed buyer, address indexed recipient, uint256 totalEth, uint256 ethFee, uint256 ethSold, uint256 tokensBought, uint256 buyerTokenBalance, uint256 totalSupply, bool isGraduate);
  event BABTokenSell(address indexed seller, address indexed recipient, uint256 totalEth, uint256 ethFee, uint256 ethBought, uint256 tokensSold,uint256 sellerTokenBalance, uint256 totalSupply, bool isGraduate);
  event BABTokenSecondaryRewards(SecondaryRewards rewards);
  event BABMarketGraduated(address indexed tokenAddress, address indexed poolAddress, uint256 totalEthLiquidity, uint256 totalTokenLiquidity, uint256 lpPositionId, bool isGraduate);
  event BABTokenFees(address indexed tokenCreator, address indexed protocolFeeRecipient, uint256 tokenCreatorFee, uint256 protocolFee);
  event BABTokenTransfer(address indexed from, address indexed to, uint256 amount, uint256 fromTokenBalance, uint256 toTokenBalance, uint256 totalSupply);

  uint256 internal constant PRIMARY_MARKET_SUPPLY = 800_000_000e18; // 800M tokens
  uint256 internal constant SECONDARY_MARKET_SUPPLY = 200_000_000e18; // 200M tokens
  uint256 public constant TOTAL_FEE_BPS = 100;
  uint256 public constant MIN_ORDER_SIZE = 0.0000001 ether;
  uint24 public constant LP_FEE = 2500;
  int24 public constant LP_TICK_LOWER = -887250;
  int24 public constant LP_TICK_UPPER = 887250;
  
  uint256 internal constant GRADUATE_ETH = 18 ether;
  uint160 internal constant POOL_SQRT_PRICE_X96_WETH_0 = 264093875047547803988078840774656;
  uint160 internal constant POOL_SQRT_PRICE_X96_TOKEN_0 = 23768448754279299195863040;
  // Test only
  // uint256 internal constant GRADUATE_ETH = 0.06 ether;
  // uint160 internal constant POOL_SQRT_PRICE_X96_WETH_0 = 4574240095500993219205240109137920;
  // uint160 internal constant POOL_SQRT_PRICE_X96_TOKEN_0 = 1372272028650298020986880;

  address public immutable WETH;
  address public immutable nonfungiblePositionManager;
  address public immutable swapRouter;
  address public immutable protocolFeeRecipient;
  address public immutable validator;
  uint256 public immutable tradeCreatorFeeBps;
  uint256 public immutable lpCreatorFeeBps;

  IBondingCurve public bondingCurve;
  bool private isGraduate = false;
  address public platformReferrer;
  address public poolAddress;
  address public tokenCreator;
  uint256 public lpTokenId;
  string public tokenURI;

  constructor(
    string memory name,
    string memory symbol,
    string memory _tokenURI,
    address _factory,
    address _tokenCreator,
    address _validator
  ) ERC20(name, symbol) ReentrancyGuard() payable {
    tokenURI = _tokenURI;
    IBABFactory.Config memory config = IBABFactory(_factory).getConfig();
    validator = _validator;
    protocolFeeRecipient = config.protocolFeeRecipient;
    WETH = config.weth;
    nonfungiblePositionManager = config.nonfungiblePositionManager;
    swapRouter = config.swapRouter;
    bondingCurve = IBondingCurve(config.bondingCurve);

    tradeCreatorFeeBps = config.tradeCreatorFeeBps;
    lpCreatorFeeBps = config.lpCreatorFeeBps;
    
    tokenCreator = _tokenCreator;

    address token0 = WETH < address(this) ? WETH : address(this);
    address token1 = WETH < address(this) ? address(this) : WETH;
    uint160 sqrtPriceX96 = token0 == WETH ? POOL_SQRT_PRICE_X96_WETH_0 : POOL_SQRT_PRICE_X96_TOKEN_0;
    poolAddress = INonfungiblePositionManager(nonfungiblePositionManager).createAndInitializePoolIfNecessary(token0, token1, LP_FEE, sqrtPriceX96);

    if (msg.value > 0) {
      buy(_tokenCreator, _tokenCreator, 0, 0, 0x0);
    }
  }

  function buy(
    address recipient,
    address refundRecipient,
    uint256 minOrderSize,
    uint160 sqrtPriceLimitX96,
    bytes32 data
  ) public payable nonReentrant returns (uint256) {
    if (validator != address(0) && !isGraduate) {
      if (!IBABValidator(validator).validate(recipient, msg.value, data)) {
        revert ValidationFail();
      }
    }
    if (msg.value < MIN_ORDER_SIZE) revert EthAmountTooSmall();
    if (recipient == address(0)) revert AddressZero();

    // Initialize variables to store the total cost, true order size, fee, and refund if applicable
    uint256 totalCost;
    uint256 trueOrderSize;
    uint256 fee;
    uint256 refund;

    if (isGraduate) {
      fee = _calculateFee(msg.value);
      totalCost = msg.value - fee;
      _disperseFees(fee, tradeCreatorFeeBps);

      IWETH(WETH).deposit{value: totalCost}();
      IWETH(WETH).approve(swapRouter, totalCost);

      ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
        tokenIn: WETH,
        tokenOut: address(this),
        fee: LP_FEE,
        recipient: recipient,
        deadline: block.timestamp,
        amountIn: totalCost,
        amountOutMinimum: minOrderSize,
        sqrtPriceLimitX96: sqrtPriceLimitX96
      });

      trueOrderSize = ISwapRouter(swapRouter).exactInputSingle(params);
      _handleSecondaryRewards();
    } else {
      bool shouldGraduateMarket;

      (totalCost, trueOrderSize, fee, refund, shouldGraduateMarket) = _validateBondingCurveBuy(minOrderSize);
      _mint(recipient, trueOrderSize);
      _disperseFees(fee, tradeCreatorFeeBps);

      if (refund > 0) {
        (bool success, ) = refundRecipient.call{value: refund}("");
        if (!success) revert EthTransferFailed();
      }

      // Start the market if this is the final bonding market buy order.
      if (shouldGraduateMarket) {
        _graduateMarket();
      }
    }

    emit BABTokenBuy(msg.sender, recipient, msg.value, fee, totalCost, trueOrderSize, balanceOf(recipient), totalSupply(), isGraduate);

    return trueOrderSize;
  }

  function sell(
    uint256 tokensToSell,
    address recipient,
    uint256 minPayoutSize,
    uint160 sqrtPriceLimitX96
  ) external nonReentrant returns (uint256) {
    if (tokensToSell > balanceOf(msg.sender)) revert InsufficientToken();
    if (recipient == address(0)) revert AddressZero();

    uint256 truePayoutSize = isGraduate ? _handlePancakeswapSell(tokensToSell, minPayoutSize, sqrtPriceLimitX96) : _handleBondingCurveSell(tokensToSell, minPayoutSize);
    uint256 fee = _calculateFee(truePayoutSize);

    uint256 payoutAfterFee = truePayoutSize - fee;
    _disperseFees(fee, tradeCreatorFeeBps);

    (bool success, ) = recipient.call{value: payoutAfterFee}("");
    if (!success) revert EthTransferFailed();

    emit BABTokenSell(msg.sender, recipient, truePayoutSize, fee, payoutAfterFee, tokensToSell, balanceOf(recipient), totalSupply(), isGraduate);

    return truePayoutSize;
  }

  function _validateBondingCurveBuy(uint256 minOrderSize) internal returns (uint256 totalCost, uint256 trueOrderSize, uint256 fee, uint256 refund, bool startMarket) {
    totalCost = msg.value;
    fee = _calculateFee(totalCost);
    uint256 remainingEth = totalCost - fee;

    trueOrderSize = bondingCurve.getEthBuyQuote(totalSupply(), remainingEth);
    if (trueOrderSize < minOrderSize) revert SlippageBoundsExceeded();
    uint256 maxRemainingTokens = PRIMARY_MARKET_SUPPLY - totalSupply();

    if (trueOrderSize == maxRemainingTokens) {
      startMarket = true;
    }

    if (trueOrderSize > maxRemainingTokens) {
      trueOrderSize = maxRemainingTokens;
      uint256 ethNeeded = bondingCurve.getTokenBuyQuote(totalSupply(), trueOrderSize);
      fee = _calculateFee(ethNeeded);
      totalCost = ethNeeded + fee;
      if (msg.value > totalCost) {
        refund = msg.value - totalCost;
      }
      startMarket = true;
    }
  }

  function _handlePancakeswapSell(uint256 tokensToSell, uint256 minPayoutSize, uint160 sqrtPriceLimitX96) private returns (uint256) {
    bool success = transfer(address(this), tokensToSell);
    if (!success) revert InsufficientToken();

    this.approve(swapRouter, tokensToSell);

    ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
      tokenIn: address(this),
      tokenOut: WETH,
      fee: LP_FEE,
      recipient: address(this),
      deadline: block.timestamp,
      amountIn: tokensToSell,
      amountOutMinimum: minPayoutSize,
      sqrtPriceLimitX96: sqrtPriceLimitX96
    });

    uint256 payout = ISwapRouter(swapRouter).exactInputSingle(params);

    IWETH(WETH).withdraw(payout);

    return payout;
  }

  function _handleBondingCurveSell(uint256 tokensToSell, uint256 minPayoutSize) private returns (uint256) {
    uint256 payout = bondingCurve.getTokenSellQuote(totalSupply(), tokensToSell);
    if (payout < minPayoutSize) revert SlippageBoundsExceeded();
    if (payout < MIN_ORDER_SIZE) revert EthAmountTooSmall();
    _burn(msg.sender, tokensToSell);
    return payout;
  }

  function _handleSecondaryRewards() internal returns (SecondaryRewards memory) {
    if (!isGraduate) revert NotGraduate();

    INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
      tokenId: lpTokenId,
      recipient: address(this),
      amount0Max: type(uint128).max,
      amount1Max: type(uint128).max
    });

    (uint256 totalAmountToken0, uint256 totalAmountToken1) = INonfungiblePositionManager(nonfungiblePositionManager).collect(params);

    address token0 = WETH < address(this) ? WETH : address(this);
    address token1 = WETH < address(this) ? address(this) : WETH;

    SecondaryRewards memory rewards;

    rewards = _transferRewards(token0, totalAmountToken0, rewards);
    rewards = _transferRewards(token1, totalAmountToken1, rewards);

    emit BABTokenSecondaryRewards(rewards);

    return rewards;
  }

  function _transferRewards(address token, uint256 totalAmount, SecondaryRewards memory rewards) internal returns (SecondaryRewards memory) {
    if (totalAmount > 0) {
      if (token == WETH) {
        rewards.creatorAmountEth = totalAmount * lpCreatorFeeBps / 10000;
        rewards.totalAmountEth = totalAmount;
        IWETH(WETH).withdraw(totalAmount);
        _disperseFees(totalAmount, lpCreatorFeeBps);
      } else {
        rewards.creatorAmountToken = totalAmount * lpCreatorFeeBps / 10000;
        rewards.totalAmountToken = totalAmount;
        _transfer(address(this), protocolFeeRecipient, totalAmount - rewards.creatorAmountToken);
        _transfer(address(this), tokenCreator, rewards.creatorAmountToken);
      }
    }

    return rewards;
  }

  function burn(uint256 tokensToBurn) external {
    if (!isGraduate) revert NotGraduate();
    _burn(msg.sender, tokensToBurn);
  }

  function claimSecondaryRewards() external {
    _handleSecondaryRewards();
  }

  function _disperseFees(uint256 _fee, uint256 _tokenCreatorFeeBPS) internal {
    if (_tokenCreatorFeeBPS > 0) {
      uint256 tokenCreatorFee = _fee * _tokenCreatorFeeBPS / 10000;
      (bool success1, ) = tokenCreator.call{value: tokenCreatorFee}("");
      (bool success2, ) = protocolFeeRecipient.call{value: _fee - tokenCreatorFee}("");
      if (!success1 || !success2) revert EthTransferFailed();
      emit BABTokenFees(tokenCreator, protocolFeeRecipient, tokenCreatorFee, _fee - tokenCreatorFee);
    } else {
      (bool success, ) = protocolFeeRecipient.call{value: _fee}("");
      if (!success) revert EthTransferFailed();
      emit BABTokenFees(tokenCreator, protocolFeeRecipient, 0, _fee);
    }
  }

  function _calculateFee(uint256 amount) internal pure returns (uint256) {
    return (amount * TOTAL_FEE_BPS) / 10_000;
  }

  function _graduateMarket() internal {
    isGraduate = true;
    _disperseFees(address(this).balance - GRADUATE_ETH, 0);

    uint256 ethLiquidity = address(this).balance;

    IWETH(WETH).deposit{value: ethLiquidity}();

    _mint(address(this), SECONDARY_MARKET_SUPPLY);

    IERC20(WETH).approve(address(nonfungiblePositionManager), ethLiquidity);
    IERC20(this).approve(address(nonfungiblePositionManager), SECONDARY_MARKET_SUPPLY);

    bool isWethToken0 = address(WETH) < address(this);
    address token0 = isWethToken0 ? WETH : address(this);
    address token1 = isWethToken0 ? address(this) : WETH;
    uint256 amount0 = isWethToken0 ? ethLiquidity : SECONDARY_MARKET_SUPPLY;
    uint256 amount1 = isWethToken0 ? SECONDARY_MARKET_SUPPLY : ethLiquidity;

    INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
      token0: token0,
      token1: token1,
      fee: LP_FEE,
      tickLower: LP_TICK_LOWER,
      tickUpper: LP_TICK_UPPER,
      amount0Desired: amount0,
      amount1Desired: amount1,
      amount0Min: 0,
      amount1Min: 0,
      recipient: address(this),
      deadline: block.timestamp
    });

    (lpTokenId, , , ) = INonfungiblePositionManager(nonfungiblePositionManager).mint(params);
    emit BABMarketGraduated(address(this), poolAddress, ethLiquidity, SECONDARY_MARKET_SUPPLY, lpTokenId, isGraduate);
  }

  function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
    if (msg.sender != poolAddress) {
      revert OnlyPool();
    }
    return this.onERC721Received.selector;
  }

  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {}

  function getIsGraduate() external view returns (bool) {
    return isGraduate;
  }

  receive() external payable {
    if (msg.sender == WETH) {
      return;
    }

    if (isGraduate) {
      buy(msg.sender, msg.sender, 0, 0, 0x0);
    }
  }

  function _update(address from, address to, uint256 value) internal virtual override {
    if (!isGraduate && to == poolAddress) revert NotGraduate();

    super._update(from, to, value);

    emit BABTokenTransfer(from, to, value, balanceOf(from), balanceOf(to), totalSupply());
  }

}