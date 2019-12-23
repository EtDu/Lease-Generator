pragma solidity ^0.5.1;
import "./SafeMath.sol";
import "./provableAPI.sol";

contract LeaseGenerator is usingProvable {

    using SafeMath for uint;

    address payable landlordAddress;
    uint ETHUSD;

    address payable tenantAddress;
    uint tenantPayment;

    enum State {
        payingLeaseDeposit,
        payingLease,
        collectingLeaseDeposit,
        reclaimingLeaseDeposit,
        idle
    }

    State workingState;

    struct Lease {
        uint8 numberOfMonths;
        uint8 monthsPaid;
        uint16 monthlyAmountUsd;
        uint16 leaseDepositUsd;
        uint32 leasePaymentWindowSeconds;
        uint64 paymentWindowEnd;
        uint64 depositPaymentWindowEnd;
        bool leaseDepositPaid;
        bool leaseFullyPaid;
        bool leaseClosed;
    }

    event leaseCreated(
        uint8 numberOfMonths,
        uint8 monthsPaid,
        uint16 monthlyAmountUsd,
        uint16 leaseDepositUsd,
        uint32 leasePaymentWindowSeconds,
        bool leaseDepositPaid,
        bool leaseFullyPaid,
        bool leaseClosed
    );

    event leaseDepositPaid(
        address tenantAddress,
        uint amountSentUsd,
        uint leaseDepositUsd
    );

    event leasePaymentPaid(
        address tenantAddress,
        uint amountSentUsd
    );

    event leaseDepositCollected(
        address tenantAddress,
        uint amountCollected
    );

    event leaseDepositReclaimed(
        address tenantAddress,
        uint amountReclaimed
    );

    event leaseFullyPaid(
        address tenantAddress,
        uint numberOfmonths,
        uint monthsPaid
    );

    mapping (bytes32 => bool) validIds;
    mapping (address => Lease) tenantLease;

    modifier onlyLandlord() {
        require(msg.sender == landlordAddress, "Must be the landlord to create a lease");
        _;
    }

    constructor () public payable {
            landlordAddress = msg.sender;
            provable_setCustomGasPrice(100000000000);
            OAR = OracleAddrResolverI(0x6f485C8BF6fc43eA212E93BBF8ce046C7f1cb475);
    }

    function fetchUsdRate() internal {
        require(provable_getPrice("URL") < address(this).balance, "Not enough Ether in contract, please add more");
        bytes32 queryId = provable_query("URL", "json(https://api.pro.coinbase.com/products/ETH-USD/ticker).price");
        validIds[queryId] = true;
    }

    function __callback(bytes32 myId, string memory result) public {
        require(validIds[myId], "Provable query IDs do not match, no valid call was made to provable_query()");
        require(msg.sender == provable_cbAddress(), "Calling address does match usingProvable contract address ");
        validIds[myId] = false;
        ETHUSD = parseInt(result);

        if (workingState == State.payingLeaseDeposit) {
            _payLeaseDeposit();
        } else if (workingState == State.payingLease) {
            _payLease();
        } else if (workingState == State.collectingLeaseDeposit) {
            _collectLeaseDeposit();
        }
    }

    function createNewLease(
            uint8 numberOfMonths,
            uint16 monthlyAmountUsd,
            uint16 leaseDepositUsd,
            uint32 leasePaymentWindowSeconds,
            uint32 depositPaymentWindowSeconds,
            address payable tenantAddr
        ) public onlyLandlord {

        uint64 depositPaymentWindowEnd = uint64(now.add(depositPaymentWindowSeconds));

        tenantLease[tenantAddr] = Lease(
            numberOfMonths,
            0,
            monthlyAmountUsd,
            leaseDepositUsd,
            leasePaymentWindowSeconds,
            0,
            depositPaymentWindowEnd,
            false,
            false,
            false
        );

        emit leaseCreated(
            numberOfMonths,
            0,
            monthlyAmountUsd,
            leaseDepositUsd,
            leasePaymentWindowSeconds,
            false,
            false,
            false
        );
    }

    function payLeaseDeposit() public payable {
        Lease storage lease = tenantLease[msg.sender];
        require(!lease.leaseDepositPaid, "Lease deposit is already paid.");
        require(lease.depositPaymentWindowEnd >= now, "Lease deposit payment must fit into payment window");

        tenantAddress = msg.sender;
        tenantPayment = msg.value;
        workingState = State.payingLeaseDeposit;
        fetchUsdRate();
    }

    function _payLeaseDeposit() internal {
        workingState = State.idle;
        Lease storage lease = tenantLease[tenantAddress];
        uint amountSentUsd = tenantPayment.mul(ETHUSD).div(1e18);

        require(
            amountSentUsd >= lease.leaseDepositUsd - 3 &&
            amountSentUsd <= lease.leaseDepositUsd + 3,
            "Deposit payment must equal the specified amount with a maximum offset of $3");

        lease.leaseDepositPaid = true;
        lease.depositPaymentWindowEnd = 0;

        emit leaseDepositPaid(
            tenantAddress,
            amountSentUsd,
            lease.leaseDepositUsd
        );
    }

    function payLease() public payable {
        Lease storage lease = tenantLease[msg.sender];
        require(lease.leaseDepositPaid, "Lease deposit must be paid before making lease payments");
        require(!lease.leaseFullyPaid, "Lease has already been fully paid");
        require(lease.paymentWindowEnd >= now, "Lease payment must fit into payment window");

        tenantAddress = msg.sender;
        tenantPayment = msg.value;
        workingState = State.payingLease;
        fetchUsdRate();
    }

    function _payLease() internal {
        workingState = State.idle;
        Lease storage lease = tenantLease[tenantAddress];
        uint amountSentUsd = tenantPayment.mul(ETHUSD).div(1e18);

        require(
            amountSentUsd >= lease.monthlyAmountUsd - 3 &&
            amountSentUsd <= lease.monthlyAmountUsd + 3,
            "Deposit payment must equal the specified amount with a maximum offset of $3");

        lease.monthsPaid = lease.monthsPaid + 1;

        if (lease.monthsPaid == lease.numberOfMonths) {
            lease.leaseFullyPaid = true;
            lease.paymentWindowEnd = 0;

            emit leaseFullyPaid(
                tenantAddress,
                lease.numberOfMonths,
                lease.monthsPaid
            );
        } else {
            lease.paymentWindowEnd = lease.paymentWindowEnd + lease.leasePaymentWindowSeconds;

            emit leasePaymentPaid(
                tenantAddress,
                amountSentUsd
            );
        }
    }

    function collectLeaseDeposit(address payable tenantAddr) public onlyLandlord {
        Lease storage lease = tenantLease[tenantAddr];
        require(!lease.leaseFullyPaid, "Cannot collect lease deposit if lease is already paid");
        require(lease.paymentWindowEnd <= now, "Lease payment must be overdue past payment window to collect lease deposit");
        require(lease.leaseDepositUsd > 0, "Lease deposit has already been removed");

        tenantAddress = tenantAddr;
        workingState = State.collectingLeaseDeposit;
        fetchUsdRate();
    }

    function _collectLeaseDeposit() internal {
        workingState = State.idle;
        Lease storage lease = tenantLease[tenantAddress];
        uint leaseDeposit = lease.leaseDepositUsd;
        lease.leaseDepositUsd = 0;
        landlordAddress.transfer(leaseDeposit.div(ETHUSD).mul(1e18));

        emit leaseDepositCollected(
            tenantAddress,
            leaseDeposit
        );
    }

    function reclaimLeaseDeposit() public {
        Lease storage lease = tenantLease[msg.sender];
        require(lease.leaseFullyPaid, "Lease must be fully paid to take back lease deposit");
        require(lease.leaseDepositUsd > 0, "Lease deposit has already been removed");

        tenantAddress = msg.sender;
        workingState = State.reclaimingLeaseDeposit;
        fetchUsdRate();
    }

    function _reclaimLeaseDepost() internal {
        workingState = State.idle;
        Lease storage lease = tenantLease[tenantAddress];
        uint leaseDeposit = lease.leaseDepositUsd;
        lease.leaseDepositUsd = 0;
        tenantAddress.transfer(leaseDeposit.div(ETHUSD).mul(1e18));

        emit leaseDepositReclaimed(
            tenantAddress,
            leaseDeposit
        );
    }

    function getLease(address addr) public view returns (
        uint8,
        uint8,
        uint16,
        uint16,
        uint32,
        uint64,
        uint64,
        bool,
        bool,
        bool) {
        Lease memory lease = tenantLease[addr];
        return (
            lease.numberOfMonths,
            lease.monthsPaid,
            lease.monthlyAmountUsd,
            lease.leaseDepositUsd,
            lease.leasePaymentWindowSeconds,
            lease.paymentWindowEnd,
            lease.depositPaymentWindowEnd,
            lease.leaseDepositPaid,
            lease.leaseFullyPaid,
            lease.leaseClosed);
    }

    function getRate() public view returns (uint) {
        return ETHUSD;
    }

    function getContractBalance() public view returns (uint) {
        return uint(address(this).balance);
    }
}