// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IBondingCurve {
  function getEthSellQuote(uint256 currentSupply, uint256 ethOrderSize) external pure returns (uint256);
  function getTokenSellQuote(uint256 currentSupply, uint256 tokensToSell) external pure returns (uint256);
  function getEthBuyQuote(uint256 currentSupply, uint256 ethOrderSize) external pure returns (uint256);
  function getTokenBuyQuote(uint256 currentSupply, uint256 tokenOrderSize) external pure returns (uint256);
}