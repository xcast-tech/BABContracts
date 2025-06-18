// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IBABFactory.sol";
import "./BAB.sol";
import "./interfaces/ITokenValidator.sol";
import "hardhat/console.sol";

contract BABFactory is IBABFactory, Ownable2Step {

  error InsufficientFee();

  event BABTokenCreated(address indexed tokenAddress, address indexed creator, string name, string symbol, string tokenURI, address validator, Config config);

  Config private config;

  constructor(Config memory _config) Ownable(msg.sender) {
    config = _config;
  }

  function createToken(string memory name, string memory symbol, address validator, string memory tokenUri, uint256 devBuy, bytes32 _salt) external payable returns (address) {
    if (msg.value != config.createTokenFee) {
      revert InsufficientFee();
    }

    // Call TokenValidator to validate symbol
    if (config.tokenValidator != address(0)) {
      ITokenValidator(config.tokenValidator).validate(name, symbol);
    }

    BAB token = new BAB{salt: _salt, value: msg.value - config.createTokenFee}(name, symbol, tokenUri, address(this), msg.sender, validator);

    if (devBuy > 0) {
      IERC20(config.usd1).transferFrom(msg.sender, address(this), devBuy);
      IERC20(config.usd1).approve(address(token), devBuy);
      token.buy(msg.sender,  msg.sender, 0, 0, devBuy, 0x0);
    }

    emit BABTokenCreated(address(token), msg.sender, name, symbol, tokenUri, validator, config);
    return address(token);
  }

  function setConfig(Config memory _config) external onlyOwner {
    config = _config;
  }

  function getConfig() public view returns (Config memory) {
    return config;
  }

  function withdraw(address to) external onlyOwner {
    (bool success, ) = to.call{value: address(this).balance}("");
    require(success, "Failed to withdraw");
  }
}
