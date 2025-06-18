import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from 'dotenv'
dotenv.config()

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.30",
    settings: {
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  gasReporter: {
    enabled: false,
    gasPrice: 1,
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
      blockGasLimit: 139453126
    },
    sepolia: {
      url: "https://eth-sepolia.g.alchemy.com/v2/exXbF9jEMjdKGJvFGZF8-WvjO3dPojMO",
      accounts: [
        process.env.PRIVATE_KEY_SEPOLIA as string
      ],
    },
    bsc: {
      url: "https://bsc-dataseed1.binance.org/",
      accounts: [
        process.env.PRIVATE_KEY_BSC as string
      ], 
    },
    bscTest: {
      url: "https://data-seed-prebsc-1-s1.binance.org:8545/",
      accounts: [
        process.env.PRIVATE_KEY_BSC_TESTNET as string
      ], 
    },
  },
  etherscan: {
    apiKey: process.env.API_KEY as string,
  },
};

export default config;
