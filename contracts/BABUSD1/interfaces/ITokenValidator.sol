// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ITokenValidator {
  function validate(string memory name, string memory symbol) external;
  function setSymbolState(string[] memory symbols, bool[] memory isUsedStates) external;
  function isSymbolHashUsed(string memory symbol) external view returns (bool);
}