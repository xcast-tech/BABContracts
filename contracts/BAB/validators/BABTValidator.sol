// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import '../interfaces/IBABValidator.sol';

interface ISBT {
  function tokenIdOf(address from) external view returns (uint256);
}

contract BABTValidator is IBABValidator {
  error BABTNotHold();

  address constant BABTToken = 0x2B09d47D550061f995A3b5C6F0Fd58005215D7c8;

  function validate(address sender, uint256 value, bytes32 data) public view returns (bool) {
    if (ISBT(BABTToken).tokenIdOf(sender) > 0) {
      return true;
    }
    revert BABTNotHold();
  }

}