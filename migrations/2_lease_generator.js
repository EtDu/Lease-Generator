const leaseGenerator = artifacts.require('LeaseGenerator')
const SafeMath = artifacts.require('SafeMath')

module.exports = (deployer, network, accounts) => {

    deployer.deploy(SafeMath).then(() => {
        return deployer.deploy(leaseGenerator, {value: 1e18})
    })
}