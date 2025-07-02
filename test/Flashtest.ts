import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers, network } from "hardhat";
import { abi as abiFlashLoan } from "../artifacts/contracts/FlashLoan.sol/FlashLoan.json";

const WBNB = "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c";
const BUSD = "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56";
const CAKE = "0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82";

describe("BinanceFlashloanPancakeSwapV3", () => {
  describe("Deployement and testing", () => {
    it("Deployes and performs flashloan arbitrage", async () => {
      //Deploys
      const FlashLoan = await ethers.getContractFactory("FlashLoan");
      let flashloan = await FlashLoan.deploy(WBNB, BUSD, 500);
      await flashloan.deployed();
      console.log("FlashLoan Contract Deployed: ", flashloan.address);

      //Initialize Falsh Loan Params
      const amountBorrow = ethers.utils.parseUnits("30", 18);
      const tokenPath = [CAKE, WBNB];
      const routing = [1, 0, 0];
      const feeV3 = 500;

      //Create a signer
      const [signer] = await ethers.getSigners();

      //Connect to Flashloan Contract
      const contractFlashLoan = new ethers.Contract(
        flashloan.address,
        abiFlashLoan,
        signer
      );

      //Call flashloan Request Function
      const txFlashloan = await contractFlashLoan.flashLoanRequest(tokenPath,0,amountBorrow,feeV3,routing);

      //SHOW results
      const txFlashloanReceipt = await txFlashloan.await();
      expect(txFlashloanReceipt.status).to.eql(1);
    });
  });
});
