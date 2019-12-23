let lease;
let tenant;
LeaseGenerator.deployed().then((c) => { lease = c })
web3.eth.getAccounts().then((accounts) => { tenant = accounts[1] })
lease.createNewLease(100, 50, 120, 60, tenant)
lease.getLeaseInfo(tenant)
lease.payRentDeposit({ from: tenant, value: 390000000000000000})
lease.payRent({ from: tenant, value: 780000000000000000})