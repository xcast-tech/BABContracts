// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IBABValidator {
  function validate(address sender, uint256 value, bytes32 data) external returns (bool);
}