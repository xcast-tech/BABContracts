import { ZeroAddress } from "ethers";
import hre from "hardhat";


const tokenAddress = ''

const name = ''
const symbol = ''
const tokenURI = ''
const factoryAddrss = ZeroAddress
const creatorAddress = ZeroAddress
const validatorAddress = ZeroAddress

const args = [
  name, symbol, tokenURI, factoryAddrss, creatorAddress, validatorAddress
]

async function verifyBABToken() {
  const verify = await hre.run("verify:verify", {
    address: tokenAddress,
    contract: "contracts/BAB/BAB.sol:BAB",
    constructorArguments: args,
  });
  console.log(verify)
}

async function verifyBABUSD1Token() {
  const verify = await hre.run("verify:verify", {
    address: tokenAddress,
    contract: "contracts/BABUSD1/BAB.sol:BAB",
    constructorArguments: args,
  });
  console.log(verify)
}


async function main() {
  // await verifyBABToken()
  // await verifyBABUSD1Token()
}

main()
