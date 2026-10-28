// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title HarborWatch
 * @notice Bonded uptime pledges on BOT Chain.
 *
 * An operator opens a watch over a service, posts a bond, and declares how
 * often they will check in. Every `intervalSecs` they must call `pulse`.
 * Miss the deadline and *anyone* can raise the alarm: a slice of the bond is
 * slashed, the caller keeps a bounty, and the rest goes to the protocol.
 *
 * Nobody privileged decides whether a service was up. The deadline is the
 * only judge, and the alarm is permissionless.
 *
 * Design notes
 * - Slashing does not end the watch. The bond shrinks and the clock restarts,
 *   so a flaky operator bleeds rather than being cut off in one event.
 * - When the bond falls below `minBond` the watch is Breached and terminal.
 * - Closing is delayed by `CLOSE_DELAY`, and refused while overdue, so an
 *   operator cannot see an outage coming and walk away with the whole bond.
 * - An owner pause freezes slashing. On unpause every watch gets a fresh
 *   full interval, so an admin pause can never cause a wave of slashes.
 */
contract HarborWatch is Ownable, Pausable, ReentrancyGuard {
    enum Status {
        Active,
        Breached,
        Closed
    }

    struct Watch {
        address operator;
        uint64 intervalSecs;
        uint64 lastPulse;
        uint64 createdAt;
        uint64 closeRequestedAt;
        uint256 bond;
        uint32 pulseCount;
        uint32 strikes;
        Status status;
        string label;
    }

    uint64 public constant MIN_INTERVAL = 1 hours;
    uint64 public constant MAX_INTERVAL = 30 days;
    uint64 public constant GRACE = 15 minutes;
    uint64 public constant CLOSE_DELAY = 24 hours;
    uint16 public constant MAX_SLASH_BPS = 5000;
    uint256 public constant MAX_LABEL = 64;

    /// @notice Share of the remaining bond burned off on each missed deadline.
    uint16 public slashBps = 2000;
    /// @notice Share of each slash paid to whoever raised the alarm.
    uint16 public challengerBps = 5000;
    /// @notice Smallest bond a watch may hold and stay Active.
    uint256 public minBond = 0.01 ether;

    uint256 public accumulatedFees;
    uint256 public bondedTotal;
    /// @notice Timestamp of the last unpause; every watch gets a full interval from here.
    uint64 public lastUnpausedAt;

    Watch[] private _watches;
    mapping(address => uint256[]) private _byOperator;

    event WatchOpened(uint256 indexed id, address indexed operator, string label, uint64 intervalSecs, uint256 bond);
    event Pulsed(uint256 indexed id, address indexed operator, uint64 at, uint32 pulseCount);
    event BondToppedUp(uint256 indexed id, uint256 amount, uint256 newBond);
    event AlarmRaised(uint256 indexed id, address indexed challenger, uint256 slashed, uint256 bounty, uint256 remainingBond);
    event WatchBreached(uint256 indexed id);
    event CloseRequested(uint256 indexed id, uint64 closableAt);
    event WatchClosed(uint256 indexed id, uint256 refunded);
    event ParamsUpdated(uint16 slashBps, uint16 challengerBps, uint256 minBond);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {
        lastUnpausedAt = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- open

    function openWatch(string calldata label, uint64 intervalSecs)
        external
        payable
        whenNotPaused
        returns (uint256 id)
    {
        require(bytes(label).length > 0 && bytes(label).length <= MAX_LABEL, "bad label");
        require(intervalSecs >= MIN_INTERVAL && intervalSecs <= MAX_INTERVAL, "bad interval");
        require(msg.value >= minBond, "bond too small");

        id = _watches.length;
        _watches.push(
            Watch({
                operator: msg.sender,
                intervalSecs: intervalSecs,
                lastPulse: uint64(block.timestamp),
                createdAt: uint64(block.timestamp),
                closeRequestedAt: 0,
                bond: msg.value,
                pulseCount: 0,
                strikes: 0,
                status: Status.Active,
                label: label
            })
        );
        _byOperator[msg.sender].push(id);
        bondedTotal += msg.value;

        emit WatchOpened(id, msg.sender, label, intervalSecs, msg.value);
    }

    // --------------------------------------------------------------- pulse

    /// @dev Allowed while paused: an operator must always be able to check in.
    function pulse(uint256 id) external {
        Watch storage w = _at(id);
        require(w.operator == msg.sender, "not operator");
        require(w.status == Status.Active, "not active");

        w.lastPulse = uint64(block.timestamp);
        unchecked {
            w.pulseCount += 1;
        }
        emit Pulsed(id, msg.sender, w.lastPulse, w.pulseCount);
    }

    function topUpBond(uint256 id) external payable nonReentrant {
        Watch storage w = _at(id);
        require(w.operator == msg.sender, "not operator");
        require(w.status != Status.Closed, "closed");
        require(msg.value > 0, "nothing sent");

        w.bond += msg.value;
        bondedTotal += msg.value;

        // A top-up that clears the floor brings a breached watch back to life,
        // with a fresh interval to prove itself.
        if (w.status == Status.Breached && w.bond >= minBond) {
            w.status = Status.Active;
            w.lastPulse = uint64(block.timestamp);
        }
        emit BondToppedUp(id, msg.value, w.bond);
    }

    // --------------------------------------------------------------- alarm

    /**
     * @notice Slash an overdue watch. Anyone may call this.
     * @dev Blocked while paused, and the post-unpause interval protects
     *      operators from an admin pause they did not ask for.
     */
    function raiseAlarm(uint256 id) external nonReentrant whenNotPaused {
        Watch storage w = _at(id);
        require(w.status == Status.Active, "not active");
        require(block.timestamp > dueAt(id), "not overdue");

        uint256 slashed = (w.bond * slashBps) / 10_000;
        if (slashed == 0) slashed = w.bond; // dust bond: take it all
        uint256 bounty = (slashed * challengerBps) / 10_000;
        uint256 toFees = slashed - bounty;

        w.bond -= slashed;
        bondedTotal -= slashed;
        accumulatedFees += toFees;
        unchecked {
            w.strikes += 1;
        }
        // Clock restarts: the operator gets one more interval to recover.
        w.lastPulse = uint64(block.timestamp);

        if (w.bond < minBond) {
            w.status = Status.Breached;
            emit WatchBreached(id);
        }

        emit AlarmRaised(id, msg.sender, slashed, bounty, w.bond);

        if (bounty > 0) {
            (bool ok, ) = payable(msg.sender).call{value: bounty}("");
            require(ok, "bounty failed");
        }
    }

    // --------------------------------------------------------------- close

    function requestClose(uint256 id) external {
        Watch storage w = _at(id);
        require(w.operator == msg.sender, "not operator");
        require(w.status == Status.Active, "not active");
        require(w.closeRequestedAt == 0, "already requested");

        w.closeRequestedAt = uint64(block.timestamp);
        emit CloseRequested(id, uint64(block.timestamp) + CLOSE_DELAY);
    }

    /**
     * @notice Reclaim the remaining bond.
     * @dev Active watches must have served the close delay and must not be
     *      overdue at the moment of closing. A Breached watch is already
     *      finished, so it closes straight away.
     */
    function closeWatch(uint256 id) external nonReentrant {
        Watch storage w = _at(id);
        require(w.operator == msg.sender, "not operator");
        require(w.status != Status.Closed, "closed");

        if (w.status == Status.Active) {
            require(w.closeRequestedAt != 0, "request first");
            require(block.timestamp >= w.closeRequestedAt + CLOSE_DELAY, "delay not served");
            require(block.timestamp <= dueAt(id), "overdue");
        }

        uint256 refund = w.bond;
        w.bond = 0;
        w.status = Status.Closed;
        if (refund > 0) bondedTotal -= refund;

        emit WatchClosed(id, refund);

        if (refund > 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            require(ok, "refund failed");
        }
    }

    // --------------------------------------------------------------- views

    /// @notice The moment a watch becomes slashable.
    function dueAt(uint256 id) public view returns (uint256) {
        Watch storage w = _at(id);
        uint256 fromPulse = uint256(w.lastPulse) + w.intervalSecs;
        uint256 fromUnpause = uint256(lastUnpausedAt) + w.intervalSecs;
        uint256 base = fromPulse > fromUnpause ? fromPulse : fromUnpause;
        return base + GRACE;
    }

    function isOverdue(uint256 id) external view returns (bool) {
        Watch storage w = _at(id);
        return w.status == Status.Active && block.timestamp > dueAt(id);
    }

    function secondsRemaining(uint256 id) external view returns (uint256) {
        uint256 due = dueAt(id);
        return block.timestamp >= due ? 0 : due - block.timestamp;
    }

    function getWatch(uint256 id) external view returns (Watch memory) {
        return _at(id);
    }

    function watchCount() external view returns (uint256) {
        return _watches.length;
    }

    function getWatchesByOperator(address operator) external view returns (uint256[] memory) {
        return _byOperator[operator];
    }

    /// @notice Newest-first page of watch ids.
    function getRecent(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _watches.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    // --------------------------------------------------------------- admin

    function setParams(uint16 newSlashBps, uint16 newChallengerBps, uint256 newMinBond) external onlyOwner {
        require(newSlashBps > 0 && newSlashBps <= MAX_SLASH_BPS, "slash out of range");
        require(newChallengerBps <= 10_000, "challenger out of range");
        require(newMinBond > 0, "min bond zero");
        slashBps = newSlashBps;
        challengerBps = newChallengerBps;
        minBond = newMinBond;
        emit ParamsUpdated(newSlashBps, newChallengerBps, newMinBond);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
        lastUnpausedAt = uint64(block.timestamp);
    }

    /// @dev Bounded by `accumulatedFees`, so operator bonds are never reachable.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "bad recipient");
        uint256 amount = accumulatedFees;
        require(amount > 0, "nothing to withdraw");
        accumulatedFees = 0;
        emit FeesWithdrawn(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------ internal

    function _at(uint256 id) private view returns (Watch storage) {
        require(id < _watches.length, "no such watch");
        return _watches[id];
    }

    /// @dev Stray BOT becomes protocol fees rather than unaccounted balance.
    receive() external payable {
        accumulatedFees += msg.value;
    }
}
