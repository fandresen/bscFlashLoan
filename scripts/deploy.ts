import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Déploiement avec le compte :", deployer.address);
  console.log("Solde :", (await deployer.getBalance()).toString());

  const FlashLoan = await ethers.getContractFactory("FlashLoan");

  const token0 = "0x55d398326f99059fF775485246999027B3197955";
  const token1 = "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c";
  const poolFee = 100;
  const factory = "0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9";
  const pancakeswapRouter = "0x1b81D678ffb9C0263b24A97847620C99d213eB14";
  const uniswapRouter = "0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2";

  const contract = await FlashLoan.deploy(token0,token1,poolFee,factory,pancakeswapRouter,uniswapRouter);

  await contract.deployed();

  console.log("Contrat déployé à :", contract.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
