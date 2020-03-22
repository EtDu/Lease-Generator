const LeaseGenerator = artifacts.require('LeaseGenerator')
const assertRevert = require('./helpers/assertRevert')
const subscribe = require('./helpers/subscribe')
const timer = require('./helpers/timer')
const axios = require('axios')
web3.setProvider('ws://localhost:8546')

contract("LeaseGenerator", (accounts) => {
    const initialWeiBalance = '100000000000000'
    let leaseGenerator
    const leaseObject = {
        'numberOfMonths': '0',
        'monthsPaid': '1',
        'monthlyAmountUsd': '2',
        'leaseDepositUsd': '3',
        'leasePaymentWindowSeconds': '4',
        'paymentWindowEnd': '5',
        'depositPaymentWindowEnd': '6',
        'leaseDepositPaid': '7',
        'leaseFullyPaid': '8',
    }

    const landlord = accounts[0]
    const tenant = accounts[1]
    const anotherTenant = accounts[2]
    let usdRate 
    let depositPaymentAmount
    let leasePaymentAmount
    let leasePaymentAmountFull

    beforeEach(async () => {
        rate = await axios.get('https://api.pro.coinbase.com/products/ETH-USD/ticker')
        usdRate = rate.data.price
        depositPaymentAmount = 500 / usdRate * 1e18
        leasePaymentAmount = 1000 / usdRate * 1e18
        leasePaymentAmountFull = 2000 / usdRate * 1e18
        
        leaseGenerator = await LeaseGenerator.new({
            from: landlord,
            value: initialWeiBalance,
            gas: 6721975,
        })
    })
    
    describe("Deployment", async () => {
        it("Deploys successfully with an Ether balance", async () => {
            const addr = leaseGenerator.address;
            assert.notEqual(addr, 0x0)
            assert.notEqual(addr, '')
            assert.notEqual(addr, null)
            assert.notEqual(addr, undefined)

            const balance = await leaseGenerator.getContractBalance()
            assert.equal(balance, initialWeiBalance, "Ether balance matches expected")
        })
    })

    describe("Creating a lease", async () => {
        let event

        beforeEach(async () => {
            const result = await leaseGenerator.createNewLease(2, 1000, 500, 120, 60, tenant, { from: landlord })
            event = result.logs[0].args
        })


        it("Landlord creates a new lease with given parameters", async () => {
            assert.equal(event.numberOfMonths, 2, "Number of months is 2")
            assert.equal(event.monthsPaid, 0, "No months are paid yet")
            assert.equal(event.monthlyAmountUsd, 1000, "Monthly payments are $1000")
            assert.equal(event.leaseDepositUsd, 500, "Lease deposit is $500")
            assert.equal(event.leasePaymentWindowSeconds, 120, "Lease payment window is 120 seconds")
            assert.isNotOk(event.leaseDepositPaid, "Lease deposit is not yet paid")
            assert.isNotOk(event.leaseFullyPaid, "Lease has not been fully paid")
            assert.isNotOk(event.leaseClosed, "Lease is not closed")
        })

        it ("Fails if caller is not landlord", async () => {
            await assertRevert(leaseGenerator.createNewLease(2, 1000, 500, 120, 60, anotherTenant, { from: tenant }))
        })
    })

    describe("Paying a lease deposit", async () => {
        beforeEach(async() => {
            await leaseGenerator.createNewLease(2, 1000, 500, 120, 15, tenant, { from: landlord })
        })

        it("Tenant can pay a lease desposit", async () => {
            await leaseGenerator.payLeaseDeposit({ from: tenant, value: depositPaymentAmount })
            await subscribe(leaseGenerator)
            const lease = await leaseGenerator.getLease(tenant)

            const leaseDepositPaid = lease[leaseObject['leaseDepositPaid']]
            const depositPaymentWindowEnd = lease[leaseObject['depositPaymentWindowEnd']]
            assert.isOk(leaseDepositPaid)
            assert.equal(depositPaymentWindowEnd, 0)
        })

        it("Should fail if deposit is already paid", async () => {
            await leaseGenerator.payLeaseDeposit({ from: tenant, value: depositPaymentAmount })
            await assertRevert(leaseGenerator.payLeaseDeposit({ from: tenant, value: depositPaymentAmount })) 
        })

        it ("Should fail if deposit amount is not within $5 offset of deposit rate", async () => {
            await assertRevert(leaseGenerator.payLeaseDeposit({ from: tenant, value: (depositPaymentAmount + 1000) }))
        })
    })

    describe("Paying a lease", async () => {
        beforeEach(async() => {
            await leaseGenerator.createNewLease(2, 1000, 500, 120, 30, anotherTenant, { from: landlord })
        })

        it("Tenant can pay lease", async () => {
            await leaseGenerator.payLeaseDeposit({ from: anotherTenant, value: depositPaymentAmount })
            await subscribe(leaseGenerator)
            await leaseGenerator.payLease({ from: anotherTenant, value: leasePaymentAmount })
            await subscribe(leaseGenerator)
            const lease = await leaseGenerator.getLease(anotherTenant)

            const monthsPaid = lease[leaseObject['monthsPaid']]
            assert.equal(monthsPaid, 1)
        })
        
        it("Should fail if lease deposit not yet paid", async () => {
            await assertRevert(leaseGenerator.payLease({ from: anotherTenant, value: leasePaymentAmount }))
        })
        
        it("Should fail if lease is already fully paid", async () => {
            await leaseGenerator.payLeaseDeposit({ from: anotherTenant, value: depositPaymentAmount })
            await subscribe(leaseGenerator)
            await leaseGenerator.payLease({ from: anotherTenant, value: leasePaymentAmountFull })
            await subscribe(leaseGenerator)
            await assertRevert(leaseGenerator.payLease({ from: anotherTenant, value: leasePaymentAmountFull }))
        })  

        it("Should fail if amount sent is less than monthly rate with an offset of $5", async () => {
            await leaseGenerator.payLeaseDeposit({ from: anotherTenant, value: depositPaymentAmount })
            await subscribe(leaseGenerator)
            await assertRevert(leaseGenerator.payLease({ from: anotherTenant, value: depositPaymentAmount }))
        })  
    })

    describe("Collecting a lease deposit", async () => {
        it("Should fail if payment not overdue", async () => {
            await leaseGenerator.createNewLease(2, 1000, 500, 60, 30, anotherTenant, { from: landlord })
            await leaseGenerator.payLeaseDeposit({ from: anotherTenant, value: depositPaymentAmount })
            await subscribe(leaseGenerator)
            await assertRevert(leaseGenerator.collectLeaseDeposit(anotherTenant, { from: landlord }))
        })

        beforeEach(async () => {
            await leaseGenerator.createNewLease(2, 1000, 500, 3, 30, anotherTenant, { from: landlord })
            await leaseGenerator.payLeaseDeposit({ from: anotherTenant, value: depositPaymentAmount })
            await subscribe(leaseGenerator)
            await timer()
        })

        it ("Landlord collects a lease deposit successfully", async () => {
            const landlordBalance = await web3.eth.getBalance(landlord)
            await leaseGenerator.collectLeaseDeposit(anotherTenant, { from: landlord })
            await subscribe(leaseGenerator)
            const newLandlordBalance = await web3.eth.getBalance(landlord)
            
            assert.notEqual(landlordBalance, newLandlordBalance)
        })

        it ("Fails if lease is already paid", async () => {
            await leaseGenerator.payLease({ from: anotherTenant, value: leasePaymentAmountFull })
            await subscribe(leaseGenerator)

            await assertRevert(leaseGenerator.collectLeaseDeposit(anotherTenant, { from: landlord }))
        })

        it ("Fails if the caller is not the landlord", async () => {
            await assertRevert(leaseGenerator.collectLeaseDeposit(anotherTenant, { from: tenant }))
        })

        it ("Fails if lease deposit has already been taken", async () => {
            await leaseGenerator.collectLeaseDeposit(anotherTenant, { from: landlord })
            await subscribe(leaseGenerator)

            await assertRevert(leaseGenerator.collectLeaseDeposit(anotherTenant, { from: landlord }))
        })
    })

    describe("Reclaiming a lease deposit", async () => {
        beforeEach(async () => {
            await leaseGenerator.createNewLease(2, 1000, 500, 60, 30, anotherTenant, { from: landlord })
            await leaseGenerator.payLeaseDeposit({ from: anotherTenant, value: depositPaymentAmount })
            await subscribe(leaseGenerator)
        })

        it("Tenant reclaims a lease deposit successfully", async () => {
            await leaseGenerator.payLease({ from: anotherTenant, value: leasePaymentAmountFull })
            await subscribe(leaseGenerator)
            const tenantBalance = await web3.eth.getBalance(anotherTenant)
            await leaseGenerator.reclaimLeaseDeposit({ from: anotherTenant })
            await subscribe(leaseGenerator)
            const newTenantBalance = await web3.eth.getBalance(anotherTenant)
            
            assert.notEqual(tenantBalance, newTenantBalance)
        })
        
        it("Fails if lease is not fully paid", async () => {
            await leaseGenerator.payLease({ from: anotherTenant, value: leasePaymentAmount })
            await subscribe(leaseGenerator)

            await assertRevert(leaseGenerator.reclaimLeaseDeposit({ from: anotherTenant }))
        })
        
        it("Fails if lease deposit has already been taken", async () => {
            await leaseGenerator.payLease({ from: anotherTenant, value: leasePaymentAmountFull })
            await subscribe(leaseGenerator)
            await leaseGenerator.reclaimLeaseDeposit({ from: anotherTenant })
            await subscribe(leaseGenerator)

            await assertRevert(leaseGenerator.reclaimLeaseDeposit({ from: anotherTenant }))
        })
    })

    describe("Withdrawing funds", async () => {
        beforeEach(async () => {
            await leaseGenerator.createNewLease(2, 1000, 500, 60, 30, anotherTenant, { from: landlord })
            await leaseGenerator.payLeaseDeposit({ from: anotherTenant, value: depositPaymentAmount })
            await subscribe(leaseGenerator)
            await leaseGenerator.payLease({ from: anotherTenant, value: leasePaymentAmountFull })
            await subscribe(leaseGenerator)
        })

        it("Landlord withdraws funds successfully", async () => {
            const landlordBalance = await web3.eth.getBalance(landlord)
            await leaseGenerator.withdrawFunds({ from: landlord })
            const newLandlordBalance = await web3.eth.getBalance(landlord)

            assert.notEqual(landlordBalance, newLandlordBalance)
        })

        it("Correctly sets leaseBalance to 0", async () => {
            const withdraw = await leaseGenerator.withdrawFunds({ from: landlord })
            const leaseBalanceWei = withdraw.logs[0].args.leaseBalanceWei

            assert.equal(leaseBalanceWei, 0)
        })

        it("Fails if leaseBalance is 0 or less than 0", async () => {
            await leaseGenerator.withdrawFunds({ from: landlord })

            await assertRevert(leaseGenerator.withdrawFunds({ from: landlord }))
        })
    })
})