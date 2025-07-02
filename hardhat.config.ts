import { HardhatUserConfig } from "hardhat/config";
import dotenv from "dotenv";
import "@nomicfoundation/hardhat-toolbox";

dotenv.config();

const mainnet_provider_url = process.env.MAINNET_PROVIDER_URL!;
const testnet_provider_url = process.env.TESTNET_PROVIDER_URL!;
const private_key = process.env.PRIVATE_KEY!;

const config: HardhatUserConfig = {
  solidity: {
    compilers: [{ version: "0.8.10" }, { version: "0.8.13" }],
  },
  networks: {
    hardhat: {
      forking: { url: mainnet_provider_url },
    },
    mainnet: {
      url: testnet_provider_url,
      chainId: 56,
      accounts: [private_key],
    },
    testnet: {
      url: testnet_provider_url,
      chainId: 97,
      accounts: [private_key],
    },
  },
  mocha:{
    timeout: 120000,
  }
};

export default config;
