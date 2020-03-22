pragma solidity ^0.5.17;
import "./SafeMath.sol";
import "./provableAPI.sol";

contract LeaseGenerator is usingProvable {

    using SafeMath for uint;

    address payable landlordAddress;
    address payable tenantAddress;

    uint ETHUSD;
    uint tenantPayment;
    uint leaseBalanceWei;

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
        uint64 leasePaymentWindowEnd;
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
        uint amountSentUsd
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

    event fundsWithdrawn(
        uint transferAmount,
        uint leaseBalanceWei
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
            OAR = OracleAddrResolverI(0xB7D2d92e74447535088A32AD65d459E97f692222);
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
        } else if (workingState == State.reclaimingLeaseDeposit) {
            _reclaimLeaseDeposit();
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
            amountSentUsd >= lease.leaseDepositUsd - 5 &&
            amountSentUsd <= lease.leaseDepositUsd + 5,
            "Deposit payment must equal to the deposit amount with a maximum offset of $5");

        lease.leaseDepositPaid = true;
        lease.depositPaymentWindowEnd = 0;
        lease.leasePaymentWindowEnd = uint64(now + lease.leasePaymentWindowSeconds);

        emit leaseDepositPaid(
            tenantAddress,
            amountSentUsd
        );
    }

    function payLease() public payable {
        Lease storage lease = tenantLease[msg.sender];
        require(lease.leaseDepositPaid, "Lease deposit must be paid before making lease payments");
        require(!lease.leaseFullyPaid, "Lease has already been fully paid");
        require(lease.leasePaymentWindowEnd >= now, "Lease payment must fit into payment window");

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
            amountSentUsd >= lease.monthlyAmountUsd - 5,
            "Lease payment must be greater than or equal to the monthly amount with a maximum offset of $5");

        uint monthsPaid = uint256(lease.monthsPaid).add(amountSentUsd.add(10).div(uint256(lease.monthlyAmountUsd)));
        lease.monthsPaid = uint8(monthsPaid);
        leaseBalanceWei = leaseBalanceWei.add(tenantPayment);

        if (monthsPaid == lease.numberOfMonths) {
            lease.leaseFullyPaid = true;
            lease.leasePaymentWindowEnd = 0;

            emit leaseFullyPaid(
                tenantAddress,
                lease.numberOfMonths,
                monthsPaid
            );
        } else {
            lease.leasePaymentWindowEnd = lease.leasePaymentWindowEnd + lease.leasePaymentWindowSeconds;

            emit leasePaymentPaid(
                tenantAddress,
                amountSentUsd
            );
        }
    }

    function collectLeaseDeposit(address payable tenantAddr) public onlyLandlord {
        Lease storage lease = tenantLease[tenantAddr];
        require(!lease.leaseFullyPaid, "Cannot collect lease deposit if lease is already paid");
        require(lease.leasePaymentWindowEnd <= now, "Lease payment must be overdue past payment window to collect lease deposit");
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

    function _reclaimLeaseDeposit() internal {
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

    function withdrawFunds() public onlyLandlord {
        require(leaseBalanceWei > 0, "Lease balance must be greater than 0");
        uint transferAmount = leaseBalanceWei;
        leaseBalanceWei = 0;
        landlordAddress.transfer(transferAmount);

        emit fundsWithdrawn(
            transferAmount,
            leaseBalanceWei
        );
    }

    function getLease(address tenant) public view returns (
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
        Lease memory lease = tenantLease[tenant];
        return (
            lease.numberOfMonths,
            lease.monthsPaid,
            lease.monthlyAmountUsd,
            lease.leaseDepositUsd,
            lease.leasePaymentWindowSeconds,
            lease.leasePaymentWindowEnd,
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

    function() external payable {}
}