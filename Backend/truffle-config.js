module.exports = {
  networks: {
    development: {
      host: "127.0.0.1",
      port: 8545, // This matches the port mapping in your docker-compose
      network_id: "*",
    }
  },
  compilers: {
    solc: {
      version: "0.8.17",
    }
  },
  // Ensure paths are correct for your structure
  contracts_directory: './contracts',
  contracts_build_directory: './build/contracts'
};