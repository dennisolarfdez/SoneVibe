require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.30",
        settings: { optimizer: { enabled: true, runs: 200 }, viaIR: false }
      }
    ]
  },
  networks: {
    hardhat: {},
    soneium: {
      url: process.env.SONEIUM_RPC || "https://rpc.soneium.example",
      chainId: process.env.SONEIUM_CHAINID ? Number(process.env.SONEIUM_CHAINID) : 12345,
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : []
    }
  },
  mocha: {
    timeout: 200000
  }
};
