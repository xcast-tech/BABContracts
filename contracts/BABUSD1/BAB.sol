// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/IPancakeswapV3Pool.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IBABFactory.sol";
import "./interfaces/IBABValidator.sol";
import "./interfaces/IBondingCurve.sol";

contract BAB is ERC20, IERC721Receiver, ReentrancyGuard {

  error NotGraduate();
  error ValidationFail();
  error USD1AmountTooSmall();
  error AddressZero();
  error USD1TransferFailed();
  error InsufficientToken();
  error SlippageBoundsExceeded();
  error OnlyPool();

  struct SecondaryRewards {
    uint256 totalAmountUSD;
    uint256 totalAmountToken;
    uint256 creatorAmountUSD;
    uint256 creatorAmountToken;
  }

  event BABTokenBuy(address indexed buyer, address indexed recipient, uint256 totalUSD, uint256 USDFee, uint256 USDSold, uint256 tokensBought, uint256 buyerTokenBalance, uint256 totalSupply, bool isGraduate);
  event BABTokenSell(address indexed seller, address indexed recipient, uint256 totalUSD, uint256 USDFee, uint256 USDBought, uint256 tokensSold,uint256 sellerTokenBalance, uint256 totalSupply, bool isGraduate);
  event BABTokenSecondaryRewards(SecondaryRewards rewards);
  event BABMarketGraduated(address indexed tokenAddress, address indexed poolAddress, uint256 totalUSDLiquidity, uint256 totalTokenLiquidity, uint256 lpPositionId, bool isGraduate);
  event BABTokenFees(address indexed tokenCreator, address indexed protocolFeeRecipient, uint256 tokenCreatorFee, uint256 protocolFee);
  event BABTokenTransfer(address indexed from, address indexed to, uint256 amount, uint256 fromTokenBalance, uint256 toTokenBalance, uint256 totalSupply);

  uint256 internal constant PRIMARY_MARKET_SUPPLY = 800_000_000e18; // 800M tokens
  uint256 internal constant SECONDARY_MARKET_SUPPLY = 200_000_000e18; // 200M tokens
  uint256 public constant TOTAL_FEE_BPS = 100;
  uint256 public constant MIN_ORDER_SIZE = 0.0000001 ether;
  uint24 public constant LP_FEE = 2500;
  int24 public constant LP_TICK_LOWER = -887250;
  int24 public constant LP_TICK_UPPER = 887250;
  
  uint256 internal constant GRADUATE_USD = 12000 ether;
  uint160 internal constant POOL_SQRT_PRICE_X96_USD1_0 = 10228311798945352246088089731072;
  uint160 internal constant POOL_SQRT_PRICE_X96_TOKEN_0 = 613698707936721050850557952;

  address public immutable USD1;
  address public immutable nonfungiblePositionManager;
  address public immutable swapRouter;
  address public immutable protocolFeeRecipient;
  address public immutable validator;
  address public immutable factory;
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
    factory = _factory;
    IBABFactory.Config memory config = IBABFactory(_factory).getConfig();
    validator = _validator;
    protocolFeeRecipient = config.protocolFeeRecipient;
    USD1 = config.usd1;
    nonfungiblePositionManager = config.nonfungiblePositionManager;
    swapRouter = config.swapRouter;
    bondingCurve = IBondingCurve(config.bondingCurve);

    tradeCreatorFeeBps = config.tradeCreatorFeeBps;
    lpCreatorFeeBps = config.lpCreatorFeeBps;
    
    tokenCreator = _tokenCreator;

    address token0 = USD1 < address(this) ? USD1 : address(this);
    address token1 = USD1 < address(this) ? address(this) : USD1;
    uint160 sqrtPriceX96 = token0 == USD1 ? POOL_SQRT_PRICE_X96_USD1_0 : POOL_SQRT_PRICE_X96_TOKEN_0;
    poolAddress = INonfungiblePositionManager(nonfungiblePositionManager).createAndInitializePoolIfNecessary(token0, token1, LP_FEE, sqrtPriceX96);
  }

  function buy(
    address recipient,
    address refundRecipient,
    uint256 minOrderSize,
    uint160 sqrtPriceLimitX96,
    uint256 value,
    bytes32 data
  ) public payable nonReentrant returns (uint256) {
    if (validator != address(0) && !isGraduate && msg.sender != factory) {
      if (!IBABValidator(validator).validate(recipient, value, data)) {
        revert ValidationFail();
      }
    }
    if (value < MIN_ORDER_SIZE) revert USD1AmountTooSmall();
    if (recipient == address(0)) revert AddressZero();
    IERC20(USD1).transferFrom(msg.sender, address(this), value);

    // Initialize variables to store the total cost, true order size, fee, and refund if applicable
    uint256 totalCost;
    uint256 trueOrderSize;
    uint256 fee;
    uint256 refund;

    if (isGraduate) {
      fee = _calculateFee(value);
      totalCost = value - fee;
      _disperseFees(fee, tradeCreatorFeeBps);

      IERC20(USD1).approve(swapRouter, totalCost);

      ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
        tokenIn: USD1,
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

      (totalCost, trueOrderSize, fee, refund, shouldGraduateMarket) = _validateBondingCurveBuy(minOrderSize, value);
      _mint(recipient, trueOrderSize);
      _disperseFees(fee, tradeCreatorFeeBps);

      if (refund > 0) {
        bool success = IERC20(USD1).transfer(refundRecipient, refund);
        if (!success) revert USD1TransferFailed();
      }

      // Start the market if this is the final bonding market buy order.
      if (shouldGraduateMarket) {
        _graduateMarket();
      }
    }

    emit BABTokenBuy(msg.sender, recipient, value, fee, totalCost, trueOrderSize, balanceOf(recipient), totalSupply(), isGraduate);

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

    bool success = IERC20(USD1).transfer(msg.sender, payoutAfterFee);
    if (!success) revert USD1TransferFailed();

    if (isGraduate) {
      _handleSecondaryRewards();
    }

    emit BABTokenSell(msg.sender, recipient, truePayoutSize, fee, payoutAfterFee, tokensToSell, balanceOf(recipient), totalSupply(), isGraduate);

    return truePayoutSize;
  }

  function _validateBondingCurveBuy(uint256 minOrderSize, uint256 value) internal view returns (uint256 totalCost, uint256 trueOrderSize, uint256 fee, uint256 refund, bool startMarket) {
    totalCost = value;
    fee = _calculateFee(totalCost);
    uint256 remainingUSD = totalCost - fee;

    trueOrderSize = bondingCurve.getEthBuyQuote(totalSupply(), remainingUSD);
    if (trueOrderSize < minOrderSize) revert SlippageBoundsExceeded();
    uint256 maxRemainingTokens = PRIMARY_MARKET_SUPPLY - totalSupply();

    if (trueOrderSize == maxRemainingTokens) {
      startMarket = true;
    }

    if (trueOrderSize > maxRemainingTokens) {
      trueOrderSize = maxRemainingTokens;
      uint256 USDNeeded = bondingCurve.getTokenBuyQuote(totalSupply(), trueOrderSize);
      fee = _calculateFee(USDNeeded);
      totalCost = USDNeeded + fee;
      if (value > totalCost) {
        refund = value - totalCost;
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
      tokenOut: USD1,
      fee: LP_FEE,
      recipient: address(this),
      deadline: block.timestamp,
      amountIn: tokensToSell,
      amountOutMinimum: minPayoutSize,
      sqrtPriceLimitX96: sqrtPriceLimitX96
    });

    uint256 payout = ISwapRouter(swapRouter).exactInputSingle(params);

    return payout;
  }

  function _handleBondingCurveSell(uint256 tokensToSell, uint256 minPayoutSize) private returns (uint256) {
    uint256 payout = bondingCurve.getTokenSellQuote(totalSupply(), tokensToSell);
    if (payout < minPayoutSize) revert SlippageBoundsExceeded();
    if (payout < MIN_ORDER_SIZE) revert USD1AmountTooSmall();
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

    address token0 = USD1 < address(this) ? USD1 : address(this);
    address token1 = USD1 < address(this) ? address(this) : USD1;

    SecondaryRewards memory rewards;

    rewards = _transferRewards(token0, totalAmountToken0, rewards);
    rewards = _transferRewards(token1, totalAmountToken1, rewards);

    emit BABTokenSecondaryRewards(rewards);

    return rewards;
  }

  function _transferRewards(address token, uint256 totalAmount, SecondaryRewards memory rewards) internal returns (SecondaryRewards memory) {
    if (totalAmount > 0) {
      if (token == USD1) {
        rewards.creatorAmountUSD = totalAmount * lpCreatorFeeBps / 10000;
        rewards.totalAmountUSD = totalAmount;
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
      bool success1 = IERC20(USD1).transfer(tokenCreator, tokenCreatorFee);
      bool success2 = IERC20(USD1).transfer(protocolFeeRecipient, _fee - tokenCreatorFee);
      if (!success1 || !success2) revert USD1TransferFailed();
      emit BABTokenFees(tokenCreator, protocolFeeRecipient, tokenCreatorFee, _fee - tokenCreatorFee);
    } else {
      bool success= IERC20(USD1).transfer(protocolFeeRecipient, _fee);
      if (!success) revert USD1TransferFailed();
      emit BABTokenFees(tokenCreator, protocolFeeRecipient, 0, _fee);
    }
  }

  function _calculateFee(uint256 amount) internal pure returns (uint256) {
    return (amount * TOTAL_FEE_BPS) / 10_000;
  }

  function _graduateMarket() internal {
    isGraduate = true;
    _disperseFees(IERC20(USD1).balanceOf(address(this)) - GRADUATE_USD, 0);

    uint256 usd1Liquidity = IERC20(USD1).balanceOf(address(this));

    _mint(address(this), SECONDARY_MARKET_SUPPLY);

    IERC20(USD1).approve(address(nonfungiblePositionManager), usd1Liquidity);
    IERC20(this).approve(address(nonfungiblePositionManager), SECONDARY_MARKET_SUPPLY);

    bool isUSD1Token0 = address(USD1) < address(this);
    address token0 = isUSD1Token0 ? USD1 : address(this);
    address token1 = isUSD1Token0 ? address(this) : USD1;
    uint256 amount0 = isUSD1Token0 ? usd1Liquidity : SECONDARY_MARKET_SUPPLY;
    uint256 amount1 = isUSD1Token0 ? SECONDARY_MARKET_SUPPLY : usd1Liquidity;

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
    emit BABMarketGraduated(address(this), poolAddress, usd1Liquidity, SECONDARY_MARKET_SUPPLY, lpTokenId, isGraduate);
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
    return;
  }

  function withdraw(uint256 value) external returns(bool) {
    (bool success, ) = protocolFeeRecipient.call{value: value}("");
    return success;
  }

  function _update(address from, address to, uint256 value) internal virtual override {
    if (!isGraduate && to == poolAddress) revert NotGraduate();

    super._update(from, to, value);

    emit BABTokenTransfer(from, to, value, balanceOf(from), balanceOf(to), totalSupply());
  }

}