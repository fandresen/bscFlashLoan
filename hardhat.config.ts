require("hardhat-tracer");
import { HardhatUserConfig } from "hardhat/config";
import dotenv from "dotenv";
import "@nomicfoundation/hardhat-toolbox";

dotenv.config();

const mainnet_provider_url = process.env.MAINNET_PROVIDER_URL!;
const testnet_provider_url = process.env.TESTNET_PROVIDER_URL!;
const private_key = process.env.PRIVATE_KEY!;
const coinMarketCap_key = process.env.COIN_MARKETCAP_API_KEY!;

const config: HardhatUserConfig = {
  solidity: {
    compilers: [{ version: "0.8.20" }, { version: "0.8.13" }],
  },
  networks: {
    hardhat: {
      forking: { url: mainnet_provider_url }
    },
    mainnet: {
      url: mainnet_provider_url,
      chainId: 56,
      accounts: [private_key],
    },
    testnet: {
      url: testnet_provider_url,
      chainId: 97,
      accounts: [private_key],
    },
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency:"USD",
    coinmarketcap: coinMarketCap_key,
    gasPriceApi: "https://api.bscscan.com/api?module=proxy&action=eth_gasPrice&apikey=QYVJ82KRVRKTADXH9CGFXU8CDMP6IE5QZI"
  },
  mocha:{
    timeout: 300000,
  }
};

export default config;
