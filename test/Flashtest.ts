import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers, network } from "hardhat";
// Note: Le chemin vers l'ABI est correct pour votre projet
import { abi as FlashLoanABI } from "../artifacts/contracts/FlashLoan.sol/FlashLoan.json";
import { abi as IERC20_ABI } from "@openzeppelin/contracts/build/contracts/IERC20.json";

// --- Configuration des Adresses et Tiers de Frais (doivent correspondre à votre config.js et BSC Mainnet) ---
const WBNB_ADDRESS = "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c"; // WBNB
const USDT_ADDRESS = "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56"; // USDT

// Factories V3
const PANCAKESWAP_V3_FACTORY = "0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865";
const UNISWAP_V3_FACTORY = "0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7";

// Tiers de frais V3 (en centièmes de pourcent)
const V3_FEE_TIER_LOW = 100; // 0.01% (ajusté pour correspondance avec le contrat si 100 est 0.01%)
// Note: Votre contrat utilise 500 pour 0.05%, assurez-vous que cette constante correspond à ce que vous attendez.
// Si V3_FEE_TIER_LOW dans le contrat est 500 pour 0.05%, alors utilisez 500 ici.
// Je vais laisser 100 comme dans votre code, mais gardez cela à l'esprit.
const V3_FEE_TIER_MEDIUM = 3000; // 0.3%

// Adresse d'une baleine USDT connue sur BSC Mainnet (Binance Hot Wallet - très active)
const WHALE_ADDR_USDT = "0x174Ca62427d18b317b4226342db9E309c0fbd841";

describe("FlashLoanArbitrageV3", () => {
    // Cette fixture configure l'environnement de test, y compris le déploiement du contrat
    async function deployFlashLoanAndSetup() {
        const [deployer] = await ethers.getSigners();

        // Récupérer les interfaces des jetons
        const wbnb = new ethers.Contract(WBNB_ADDRESS, IERC20_ABI, deployer);
        const usdt = new ethers.Contract(USDT_ADDRESS, IERC20_ABI, deployer);

        // Déployer le contrat FlashLoan
        // Pour Ethers.js v5, on utilise getContractFactory().deploy() puis .deployed()
        const FlashLoan = await ethers.getContractFactory("FlashLoan");
        const flashLoanInstance = await FlashLoan.deploy(
            WBNB_ADDRESS,
            USDT_ADDRESS,
            V3_FEE_TIER_LOW,
            PANCAKESWAP_V3_FACTORY // Factory de la pool où le flash loan sera pris
        );
        await flashLoanInstance.deployed(); // <-- Correct pour Ethers.js v5

        // En Ethers.js v5, l'adresse du contrat est accessible via .address
        const contractAddress = flashLoanInstance.address;

        console.log("FlashLoan Contract deployed at:", contractAddress);
        console.log("FlashLoan Contract Owner:", await flashLoanInstance.owner());

        // --- Impersonation d'une baleine pour financer le pool de Flash Loan ---
        // Cette étape est cruciale pour s'assurer que le pool V3 a suffisamment de liquidité
        // pour que le flash loan puisse être effectué dans un environnement de test local.

        // Obtenons l'adresse du pool que notre contrat va utiliser pour le flash loan.
        const flashLoanPoolAddress = await flashLoanInstance.pool(); // 'pool' est une variable publique immutable
        console.log("Target Flash Loan Pool Address (PancakeSwap V3 WBNB/USDT 0.01%):", flashLoanPoolAddress);

        // Impersonate la baleine USDT
        await network.provider.request({
            method: "hardhat_impersonateAccount",
            params: [WHALE_ADDR_USDT],
        });
        const whaleSigner = await ethers.provider.getSigner(WHALE_ADDR_USDT);

        // Envoyer du BNB à la baleine pour les frais de transaction si elle n'en a pas
        // (nécessaire pour qu'elle puisse transférer des tokens)
        await deployer.sendTransaction({
            to: WHALE_ADDR_USDT,
            value: ethers.utils.parseEther("0.5"), // <-- utils.parseEther pour Ethers.js v5
        });
        console.log(`Sent 0.5 BNB to whale ${WHALE_ADDR_USDT} for gas.`);

        // Vérifier le solde de la baleine avant le transfert
        const whaleUSDTInitialBalance = await usdt.connect(whaleSigner).balanceOf(WHALE_ADDR_USDT);
        console.log(`Whale USDT balance before funding pool: ${ethers.utils.formatUnits(whaleUSDTInitialBalance, 6)} USDT`); // <-- utils.formatUnits pour Ethers.js v5

        const amountToFundPool = ethers.utils.parseUnits("500000", 6); // <-- utils.parseUnits pour Ethers.js v5

        if (whaleUSDTInitialBalance.lt(amountToFundPool)) { // <-- Utilisation de .lt() pour BigNumber
            console.warn("Whale does not have enough USDT to fund the pool with the desired amount.");
            console.warn("Attempting to fund with available balance or try a different whale.");
            // Si la baleine n'a pas assez, on peut ajuster le montant ou échouer le test ici.
            // Pour ce test, on va assumer qu'elle en a assez.
        }
        
        // La baleine envoie de l'USDT au pool de Flash Loan
        await usdt.connect(whaleSigner).transfer(flashLoanPoolAddress, amountToFundPool);
        console.log(`Transferred ${ethers.utils.formatUnits(amountToFundPool, 6)} USDT from whale to flash loan pool.`); // <-- utils.formatUnits
        
        // Vérifier que le pool a bien reçu les fonds
        const poolUSDTAmount = await usdt.balanceOf(flashLoanPoolAddress);
        console.log(`Flash Loan Pool USDT balance after funding: ${ethers.utils.formatUnits(poolUSDTAmount, 6)} USDT`); // <-- utils.formatUnits

        // Important: Arrêter l'impersonation après utilisation
        await network.provider.request({
            method: "hardhat_stopImpersonatingAccount",
            params: [WHALE_ADDR_USDT],
        });

        return { flashLoanInstance, deployer, wbnb, usdt, contractAddress };
    }

    describe("Flash Loan Arbitrage Execution", () => {
        it("should successfully execute a flash loan arbitrage scenario (USDT -> WBNB -> USDT)", async () => {
            const { flashLoanInstance, deployer, wbnb, usdt } = await loadFixture(deployFlashLoanAndSetup);

            // Montant à emprunter (en USDT)
            const amountToBorrowUSDT = ethers.utils.parseUnits("10000", 6); // <-- utils.parseUnits

            // Capture les soldes initiaux du deployer pour vérifier le profit/perte
            const initialUSDTDeployerBalance = await usdt.balanceOf(deployer.address);
            const initialWBNBDeployerBalance = await wbnb.balanceOf(deployer.address);

            console.log("\n--- Initiating Flash Loan Request ---");
            console.log("Borrowing USDT:", ethers.utils.formatUnits(amountToBorrowUSDT, 6)); // <-- utils.formatUnits

            // Définition des paramètres pour les deux swaps
            // SCÉNARIO: Emprunter USDT (PancakeV3), Swap USDT->WBNB (UniV3), Swap WBNB->USDT (PancakeV3), Repayer USDT
            
            // Swap 1: USDT -> WBNB sur Uniswap V3 (0.05% fee)
            const swap1Params = {
                tokenIn: USDT_ADDRESS,
                symbolIn: "USDT",
                tokenOut: WBNB_ADDRESS,
                symbolOut: "WBNB",
                fee: V3_FEE_TIER_LOW, // 0.01%
                exchange: 1, // 1 pour Uniswap V3
                amountOutMin: 0 // Pour le test, on met 0 pour ne pas bloquer la transaction sur le slippage
            };

            // Swap 2: WBNB -> USDT sur PancakeSwap V3 (0.05% fee)
            const swap2Params = {
                tokenIn: WBNB_ADDRESS,
                symbolIn: "WBNB",
                tokenOut: USDT_ADDRESS,
                symbolOut: "USDT",
                fee: V3_FEE_TIER_LOW, // 0.01%
                exchange: 0, // 0 pour PancakeSwap V3
                amountOutMin: 0 // Pour le test, on met 0 pour ne pas bloquer la transaction sur le slippage
            };

            // Appel de la fonction flashLoanRequest
            const txFlashloan = await flashLoanInstance.flashLoanRequest(
                ethers.BigNumber.from(0), // amount0ToBorrow (WBNB) = 0, doit être un BigNumber
                amountToBorrowUSDT, // amount1ToBorrow (USDT) = montant emprunté (déjà BigNumber)
                swap1Params,
                swap2Params
            );

            // Attendre la confirmation de la transaction
            const txFlashloanReceipt = await txFlashloan.wait();
            console.log(`Gas used for flashLoanRequest: ${txFlashloanReceipt.gasUsed.toString()}`);

            // Vérifier que la transaction n'a PAS été revertie
            expect(txFlashloanReceipt.status).to.equal(1, "Flash loan transaction should not revert");

            // Capturer les soldes finaux du deployer
            const finalUSDTDeployerBalance = await usdt.balanceOf(deployer.address);
            const finalWBNBDeployerBalance = await wbnb.balanceOf(deployer.address);

            console.log("\n--- Balances After Flash Loan ---");
            // Utiliser .sub() pour la soustraction de BigNumber
            console.log(`Deployer USDT Change: ${ethers.utils.formatUnits(finalUSDTDeployerBalance.sub(initialUSDTDeployerBalance), 6)} USDT`);
            console.log(`Deployer WBNB Change: ${ethers.utils.formatUnits(finalWBNBDeployerBalance.sub(initialWBNBDeployerBalance), 18)} WBNB`);

            // Assertion finale : le contrat doit avoir pu rembourser le prêt.
            // Pour un test "passant", la transaction doit juste ne pas revertir.
            // Vérifier un profit réel est très difficile dans un environnement de test simulé
            // sans une simulation de liquidité et de prix précise.
            // Ici, nous nous assurons que l'exécution atomique a eu lieu sans erreur.
        });
    });

    describe("Emergency Fund Withdrawal", () => {
        it("should allow the owner to withdraw stuck ERC20 tokens", async () => {
            const { flashLoanInstance, deployer, usdt, contractAddress } = await loadFixture(deployFlashLoanAndSetup);

            // Simuler des fonds "bloqués" en envoyant de l'USDT au contrat FlashLoan
            const stuckAmount = ethers.utils.parseUnits("100", 6); // 100 USDT
            await usdt.transfer(contractAddress, stuckAmount); // Utilisez contractAddress ici

            console.log(`\n--- Testing withdrawStuckFunds ---`);
            console.log(`Stuck USDT balance on FlashLoan contract: ${ethers.utils.formatUnits(await usdt.balanceOf(contractAddress), 6)} USDT`);

            const initialOwnerUSDTBalance = await usdt.balanceOf(deployer.address);

            // Retirer les fonds bloqués en tant que propriétaire
            await expect(flashLoanInstance.connect(deployer).withdrawStuckFunds(USDT_ADDRESS))
                .to.not.be.reverted;

            const finalOwnerUSDTBalance = await usdt.balanceOf(deployer.address);
            const finalContractUSDTBalance = await usdt.balanceOf(contractAddress);

            console.log(`Owner USDT balance before withdrawal: ${ethers.utils.formatUnits(initialOwnerUSDTBalance, 6)} USDT`);
            console.log(`Owner USDT balance after withdrawal: ${ethers.utils.formatUnits(finalOwnerUSDTBalance, 6)} USDT`);
            console.log(`Final stuck USDT balance on FlashLoan contract: ${ethers.utils.formatUnits(finalContractUSDTBalance, 6)} USDT`);

            // Vérifier que les fonds ont été transférés au propriétaire et retirés du contrat
            // Utiliser .add() pour l'addition de BigNumber
            expect(finalOwnerUSDTBalance).to.equal(initialOwnerUSDTBalance.add(stuckAmount));
            expect(finalContractUSDTBalance).to.equal(ethers.constants.Zero); // ethers.constants.Zero pour BigNumber 0
        });

        it("should revert if a non-owner tries to withdraw stuck funds", async () => {
            const { flashLoanInstance, usdt, contractAddress } = await loadFixture(deployFlashLoanAndSetup);
            const [, nonOwner] = await ethers.getSigners(); // Obtenir une adresse qui n'est pas le propriétaire

            // Simuler des fonds "bloqués"
            await usdt.transfer(contractAddress, ethers.utils.parseUnits("10", 6));

            // Tenter de retirer les fonds en tant que non-propriétaire
            await expect(flashLoanInstance.connect(nonOwner).withdrawStuckFunds(USDT_ADDRESS))
                .to.be.revertedWith("Only owner can call this function.");
        });

        it("should revert if no balance to recover", async () => {
            const { flashLoanInstance, deployer } = await loadFixture(deployFlashLoanAndSetup);

            // Tenter de retirer des fonds alors qu'il n'y en a pas
            await expect(flashLoanInstance.connect(deployer).withdrawStuckFunds(USDT_ADDRESS))
                .to.be.revertedWith("No balance to recover");
        });
    });
});