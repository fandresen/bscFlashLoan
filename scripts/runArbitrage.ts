// scripts/runArbitrage.js

async function main() {
  console.log("--- Preparation du script d'arbitrage ---");

  // --- PARAMETRES A CONFIGURER ---
  const contractAddress = "0xf6429F70044D9fcdbE0C2DA314679EBE3A2eBf78";
  const deployerAddress = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";

  // Le token que nous allons emprunter est le tokenIn du premier swap (USDT)
  // Assumons que l'USDT a 18 décimales sur ce testnet.
  const amountToBorrow = ethers.utils.parseUnits("1000", 18); // Emprunter 1000 USDT

  // Paramètres de swap fournis
  const swap1Params = [
    "0x55d398326f99059fF775485246999027B3197955", // USDT (tokenIn)
    "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", // WBNB (tokenOut)
    500, // Fee 0.05%
    1,   // Exchange: 0 pour PancakeSwap
    1n    // amountOutMin
  ];

  const swap2Params = [
    "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", // WBNB (tokenIn)
    "0x55d398326f99059fF775485246999027B3197955", // USDT (tokenOut)
    500, // Fee 0.05%
    0,   // Exchange: 1 pour Uniswap
    1n   // amountOutMin
  ];
  // --- FIN DE LA CONFIGURATION ---

  // On récupère le signer (le compte qui va envoyer la transaction)
  const signer = await ethers.getSigner(deployerAddress);
  console.log(`Utilisation du compte signer: ${signer.address}`);

  // On se connecte au contrat déjà déployé
  console.log(`Attachement au contrat FlashLoan a l'adresse: ${contractAddress}`);
  const flashLoanContract = await ethers.getContractAt("FlashLoan", contractAddress, signer);

  console.log(`\nMontant a emprunter: ${ethers.utils.formatUnits(amountToBorrow, 18)} USDT`);

  try {
    console.log("Envoi de la transaction 'executeArbitrage'...");
    
    // Appel de la fonction du contrat
    const tx = await flashLoanContract.executeArbitrage(
      amountToBorrow, // _amount0ToBorrow
      0,              // _amount1ToBorrow
      swap1Params,
      swap2Params
    );

    console.log(`Transaction envoyee. Hash: ${tx.hash}`);
    console.log("En attente de la confirmation de la transaction...");

    // On attend que la transaction soit minée
    const receipt = await tx.wait();
    
    console.log("\n--- ✅ TRANSACTION REUSSIE ---");
    console.log(`Transaction confirmee dans le bloc: ${receipt.blockNumber}`);
    console.log(`Gas utilise: ${receipt.gasUsed.toString()}`);

  } catch (error) {
    console.error("\n--- ❌ ERREUR DE TRANSACTION ---");
    // Hardhat capture et formate bien les 'revert' avec des erreurs personnalisées
    console.error(error.message);
    console.error("---------------------------------");
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });