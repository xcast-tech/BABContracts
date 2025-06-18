// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IBABFactory {
  struct Config {
    address protocolFeeRecipient;
    address weth;
    address nonfungiblePositionManager;
    address swapRouter;
    address bondingCurve;
    uint256 tradeCreatorFeeBps;
    uint256 lpCreatorFeeBps;
    uint256 createTokenFee;
    address tokenValidator;
  }

  function getConfig() external view returns (Config memory);
}
