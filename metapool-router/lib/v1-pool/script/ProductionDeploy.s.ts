import { ethers } from 'hardhat'

const CREATE2DEPLOYER = '0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2';
const ABI = [
    "function deploy(uint256 value, bytes32 salt, bytes memory code) public",
    "function computeAddress(bytes32 salt, bytes32 codeHash) public view returns (address)"
]

// Run on sepolia:
// npx hardhat run --network sepolia script/ProductionDeploy.s.ts
// Run on local fork of sepolia:
// npx hardhat run --network hardhat script/ProductionDeploy.s.ts
async function deployFactory() {
    const TRICRYPTO_FACTORY = process.env.TRICRYPTO_FACTORY;
    const OWNER = process.env.OWNER;

    if (!TRICRYPTO_FACTORY || !OWNER) {
        throw new Error('Please set TRICRYPTO_FACTORY and OWNER');
    }

    const [deployer] = await ethers.getSigners();

    const lib = await (await ethers.getContractFactory("Create2PoolLib", deployer)).deploy();
    const libAddress = lib.address
    console.log('lib.address :>> ', libAddress);

    const Factory = await ethers.getContractFactory("PoolFactory", {
        signer: deployer,
        libraries: {
            Create2PoolLib: libAddress
        },
    });
    const bytecode = Factory.bytecode as string
    const creationCode = `${bytecode}${ethers.utils.defaultAbiCoder.encode(["address"], [TRICRYPTO_FACTORY]).slice(2)}${ethers.utils.defaultAbiCoder.encode(["address"], [OWNER]).slice(2)}`
    const INIT_CODE_HASH = ethers.utils.keccak256(creationCode);
    console.log('INIT_CODE_HASH :>> ', INIT_CODE_HASH);

    // cast create2 --deployer=0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2 --init-code-hash=$INIT_CODE_HASH --starts-with=<0000000>
    const SALT = process.env.SALT;
    const precomputed = await new ethers.Contract(CREATE2DEPLOYER, ABI, deployer).computeAddress(SALT, INIT_CODE_HASH);
    console.log('precomputed :>> ', precomputed);

    // const factory = await Factory.deploy(TRICRYPTO_FACTORY, OWNER);
    const tx = await new ethers.Contract(CREATE2DEPLOYER, ABI, deployer).deploy(0, SALT, creationCode);
    await tx.wait();

    // Check if the deployment succeeded by calling the owner() function
    await Factory.attach(precomputed).owner().catch(e => {
        console.log('Wrong create2 address');
    })
    console.log('Deployment done!');
}


deployFactory().catch(console.error); 