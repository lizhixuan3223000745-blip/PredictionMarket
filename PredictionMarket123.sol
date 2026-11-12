// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Educational prediction market for testnets only.
/// @dev Internal whole-unit shares, trusted oracle, no trading fees.
contract PredictionMarket {
    uint256 public constant PAYOUT = 0.001 ether;
    uint256 public constant BASE = PAYOUT / 2;
    uint256 public constant SLOPE = 0.000001 ether;
    uint256 public constant CAP = 400;

    address public immutable owner;
    address public immutable oracle;

    uint256 public immutable closeTime;
    uint256 public immutable resolutionDeadline;

    string public question;

    // Result: 0 = unresolved, 1 = YES wins, 2 = NO wins, 3 = cancelled.
    uint8 public result;

    // Side: 0 = YES, 1 = NO.
    uint256[2] public supply;

    mapping(address => mapping(uint8 => uint256)) public shares;
    mapping(address => uint256) public netDeposit;

    uint256 public refundLiability;
    bool private entered;

    event Trade(
        address indexed user,
        uint8 indexed side,
        uint256 amount,
        uint256 weiValue,
        bool isBuy
    );

    event Resolved(uint8 result);
    event Claimed(address indexed user, uint256 weiValue);
    event SurplusWithdrawn(uint256 weiValue);

    modifier guarded() {
        require(!entered, "Reentrancy");
        entered = true;
        _;
        entered = false;
    }

    constructor(
        string memory question_,
        address oracle_,
        uint256 tradingSeconds,
        uint256 graceSeconds
    ) payable {
        require(bytes(question_).length > 0, "Empty question");
        require(oracle_ != address(0), "Invalid oracle");
        require(
            tradingSeconds > 0 && graceSeconds > 0,
            "Invalid duration"
        );
        require(
            msg.value >= CAP * PAYOUT,
            "Seed at least 0.4 ETH"
        );

        owner = msg.sender;
        oracle = oracle_;
        question = question_;

        closeTime = block.timestamp + tradingSeconds;
        resolutionDeadline = closeTime + graceSeconds;
    }

    function _cost(uint256 units) private pure returns (uint256) {
        return BASE * units + SLOPE * units * units / 2;
    }

    function buyQuote(
        uint8 side,
        uint256 amount
    ) public view returns (uint256) {
        require(side < 2 && amount > 0, "Invalid trade");
        require(amount <= CAP - supply[side], "Cap exceeded");

        return _cost(supply[side] + amount) - _cost(supply[side]);
    }

    function sellQuote(
        uint8 side,
        uint256 amount
    ) public view returns (uint256) {
        require(
            side < 2 && amount > 0 && amount <= supply[side],
            "Invalid trade"
        );

        return _cost(supply[side]) - _cost(supply[side] - amount);
    }

    function buy(
        uint8 side,
        uint256 amount
    ) external payable guarded {
        require(
            result == 0 && block.timestamp < closeTime,
            "Trading closed"
        );

        uint256 price = buyQuote(side, amount);
        require(msg.value == price, "Send exact quote in wei");

        supply[side] += amount;
        shares[msg.sender][side] += amount;
        netDeposit[msg.sender] += price;
        refundLiability += price;

        emit Trade(msg.sender, side, amount, price, true);
    }

    function sell(
        uint8 side,
        uint256 amount,
        uint256 minReturn
    ) external guarded {
        require(
            result == 0 && block.timestamp < closeTime,
            "Trading closed"
        );

        uint256 price = sellQuote(side, amount);

        require(
            shares[msg.sender][side] >= amount,
            "Insufficient shares"
        );
        require(price >= minReturn, "Slippage");

        // Preserves net-deposit accounting for timeout refunds.
        // Some profitable sales are intentionally disallowed.
        require(
            price <= netDeposit[msg.sender],
            "Return exceeds net deposit"
        );

        shares[msg.sender][side] -= amount;
        supply[side] -= amount;
        netDeposit[msg.sender] -= price;
        refundLiability -= price;

        require(
            address(this).balance >= price + _reserve(),
            "Reserve protected"
        );

        emit Trade(msg.sender, side, amount, price, false);

        _send(msg.sender, price);
    }

    function report(uint8 winningSide) external {
        require(msg.sender == oracle, "Only oracle");
        require(result == 0, "Already resolved");
        require(winningSide < 2, "Invalid side");

        require(
            block.timestamp >= closeTime &&
                block.timestamp < resolutionDeadline,
            "Wrong time"
        );

        result = winningSide + 1;

        emit Resolved(result);
    }

    function cancelExpired() external {
        require(result == 0, "Already resolved");
        require(
            block.timestamp >= resolutionDeadline,
            "Not expired"
        );

        result = 3;

        emit Resolved(3);
    }

    function claim() external guarded {
        require(result != 0, "Not resolved");

        uint256 value;

        if (result == 3) {
            value = netDeposit[msg.sender];

            netDeposit[msg.sender] = 0;
            refundLiability -= value;
        } else {
            uint8 side = result - 1;
            uint256 amount = shares[msg.sender][side];

            shares[msg.sender][side] = 0;
            supply[side] -= amount;

            value = amount * PAYOUT;
        }

        require(value > 0, "Nothing to claim");

        emit Claimed(msg.sender, value);

        _send(msg.sender, value);
    }

    function requiredReserve() external view returns (uint256) {
        return _reserve();
    }

    function _reserve() private view returns (uint256) {
        if (result == 3) {
            return refundLiability;
        }

        if (result != 0) {
            return supply[result - 1] * PAYOUT;
        }

        uint256 maximum = supply[0] > supply[1]
            ? supply[0]
            : supply[1];

        uint256 winningLiability = maximum * PAYOUT;

        return winningLiability > refundLiability
            ? winningLiability
            : refundLiability;
    }

    function withdrawSurplus() external guarded {
        require(msg.sender == owner, "Only owner");
        require(result != 0, "Not resolved");

        uint256 value = address(this).balance - _reserve();

        require(value > 0, "No surplus");

        emit SurplusWithdrawn(value);

        _send(owner, value);
    }

    function _send(address recipient, uint256 value) private {
        (bool ok, ) = payable(recipient).call{value: value}("");
        require(ok, "ETH transfer failed");
    }
}