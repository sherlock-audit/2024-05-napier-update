/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.19",
  // Avoid foundry cache conflict.
  paths: {
    sources: 'src', // Use ./src rather than ./contracts as Hardhat expects
    cache: 'hh-cache',
  },
};
