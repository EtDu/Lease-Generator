const leaseGeneratorJSON = require('../build/contracts/LeaseGenerator.json')
const truffleAssert = require('truffle-assertions');

contract("LeaseGenerator", (accounts) => {

    before(async () => {
        leaseGenerator = new web3.eth.Contract(leaseGeneratorJSON.abi, "0x42e5392D9c91ADCCF68148BA1194045b7c632A6a", { gas: 4000000})
        leaseGenerator.setProvider('ws://localhost:8546')
    })
    
    describe("deployment", async () => {
        it("Deploys successfully with an Ether balance", async () => {
            const addr = leaseGenerator._address;
            assert.notEqual(addr, 0x0)
            assert.notEqual(addr, '')
            assert.notEqual(addr, null)
            assert.notEqual(addr, undefined)

            const balance = await leaseGenerator.methods.getContractBalance().call()
            const etherBalance = balance / 1e18
            assert.isAbove(etherBalance, 0, "Ether balance is above 0")
        })
    })

    describe("Creating a lease", async () => {
        let event

        before(async () => {
            const result = await leaseGenerator.methods.createNewLease(2, 1000, 500, 120, 60, accounts[1]).send({ from: accounts[0] })
            event = result.events.leaseCreated.returnValues
        })


        it("Landlord can create a new lease with a tenant's address", async () => {
            assert.equal(event.numberOfMonths, 2, "Number of months is 2")
            assert.equal(event.monthsPaid, 0, "No months are paid yet")
            assert.equal(event.monthlyAmountUsd, 1000, "Monthly payments are $1000")
            assert.equal(event.leaseDepositUsd, 500, "Lease deposit is $500")
            assert.equal(event.leasePaymentWindowSeconds, 120, "Lease payment window is 120 seconds")
            assert.isNotOk(event.leaseDepositPaid, "Lease deposit is not yet paid")
            assert.isNotOk(event.leaseFullyPaid, "Lease has not been fully paid")
            assert.isNotOk(event.leaseClosed, "Lease is not closed")
        })
    })

    describe("Paying a lease deposit", async () => {
        let event

        before((done) => {
            leaseGenerator.methods.payLeaseDeposit().send({ from: accounts[1], value: 3.94 * 1e18 })
            leaseGenerator.once('leaseDepositPaid', (err, ev) => {
                event = ev.returnValues
                done()
            })
        })

        it("Tenant can pay a lease desposit", async () => {
            assert.equal(event.tenantAddress, accounts[1], "Is the right tenant address")
            assert.isAbove(parseInt(event.amountSentUsd), parseInt(event.leaseDepositUsd) - 3, "Amount sent is within - offset")
            assert.isBelow(parseInt(event.amountSentUsd), parseInt(event.leaseDepositUsd) + 3, "Amount sent is within + offset") 
        })

        it("Tenan't can't pay a lease deposit if already paid", async () => {
            try {
                const result = await (leaseGenerator.methods.payLeaseDeposit().send({ from: accounts[1], value: 3.94 * 1e18 }))
            } catch (e) {
                assert.equal(e.message, "Returned error: VM Exception while processing transaction: revert Lease deposit is already paid.")
            }
            
        })
    })

})