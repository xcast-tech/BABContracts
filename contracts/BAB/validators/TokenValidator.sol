// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "../interfaces/ITokenValidator.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TokenValidator is ITokenValidator, Ownable {
  // Store existing token symbol hashes
  mapping(bytes32 => bool) public existingSymbolHashes;
  
  // Track allowed callers
  mapping(address => bool) public allowedCallers;

  error DuplicateSymbol(string symbol);
  error UnauthorizedCaller(address caller);
  error InvalidSymbol(string symbol);

  constructor() Ownable(msg.sender) {}

  function validate(string memory name, string memory symbol) external {
    // Check if caller is allowed
    if (!allowedCallers[msg.sender] && msg.sender != owner()) {
      revert UnauthorizedCaller(msg.sender);
    }

    // Check if symbol is alphanumeric
    if (!isAlphanumeric(symbol)) {
      revert InvalidSymbol(symbol);
    }

    // Generate keccak256 hash of the lowercase symbol (case-insensitive)
    bytes32 symbolHash = keccak256(bytes(toLower(symbol)));
    
    // Check if symbol hash already exists
    if (existingSymbolHashes[symbolHash]) {
      revert DuplicateSymbol(symbol);
    }
    
    // Mark symbol hash as used
    existingSymbolHashes[symbolHash] = true;
  }

  // Helper function to check if a string is alphanumeric
  function isAlphanumeric(string memory str) internal pure returns (bool) {
    bytes memory b = bytes(str);
    for (uint i = 0; i < b.length; i++) {
      bytes1 char = b[i];
      if (!(char >= 0x30 && char <= 0x39) && // 0-9
          !(char >= 0x41 && char <= 0x5A) && // A-Z
          !(char >= 0x61 && char <= 0x7A)) { // a-z
        return false;
      }
    }
    return true;
  }

  // Allow owner to configure who can call the validate function
  function setCallerPermission(address caller, bool isAllowed) external onlyOwner {
    allowedCallers[caller] = isAllowed;
  }

  // Allow owner to manually set existingSymbolHashes, supporting batch operations
  function setSymbolState(string[] memory symbols, bool[] memory isUsedStates) external onlyOwner {
    require(symbols.length == isUsedStates.length, "Symbols and states must have equal length");
    
    for (uint256 i = 0; i < symbols.length; i++) {
      require(isAlphanumeric(symbols[i]), "Symbol must be alphanumeric");
      bytes32 symbolHash = keccak256(bytes(toLower(symbols[i])));
      existingSymbolHashes[symbolHash] = isUsedStates[i];
    }
  }

  // Helper function to convert string to lowercase
  function toLower(string memory str) internal pure returns (string memory) {
    bytes memory bStr = bytes(str);
    bytes memory bLower = new bytes(bStr.length);
    for (uint i = 0; i < bStr.length; i++) {
      if ((uint8(bStr[i]) >= 65) && (uint8(bStr[i]) <= 90)) {
        bLower[i] = bytes1(uint8(bStr[i]) + 32);
      } else {
        bLower[i] = bStr[i];
      }
    }
    return string(bLower);
  }

  // Function to check if a symbol hash is already used
  function isSymbolHashUsed(string memory symbol) external view returns (bool) {
    bytes32 symbolHash = keccak256(bytes(toLower(symbol)));
    return existingSymbolHashes[symbolHash];
  }
}