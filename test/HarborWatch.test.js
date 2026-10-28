const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const HOUR = 3600;
const DAY = 86400;
const GRACE = 15 * 60;
const E = (n) => ethers.parseEther(String(n));

describe("HarborWatch", function () {
  let hw, owner, op, watcher, other;

  beforeEach(async () => {
    [owner, op, watcher, other] = await ethers.getSigners();
    const F = await ethers.getContractFactory("HarborWatch");
    hw = await F.deploy();
    await hw.waitForDeployment();
  });

  async function openDefault(signer = op, interval = 6 * HOUR, bond = "1") {
    const tx = await hw.connect(signer).openWatch("rpc.example.node", interval, { value: E(bond) });
    await tx.wait();
    return (await hw.watchCount()) - 1n;
  }

  it("opens a watch and records its terms", async () => {
    const id = await openDefault();
    const w = await hw.getWatch(id);
    expect(w.operator).to.equal(op.address);
    expect(w.label).to.equal("rpc.example.node");
    expect(w.intervalSecs).to.equal(6 * HOUR);
    expect(w.bond).to.equal(E(1));
    expect(w.status).to.equal(0); // Active
    expect(await hw.bondedTotal()).to.equal(E(1));
  });

  it("rejects a bad label, a bad interval and an undersized bond", async () => {
    await expect(hw.connect(op).openWatch("", 6 * HOUR, { value: E(1) })).to.be.revertedWith("bad label");
    await expect(hw.connect(op).openWatch("x", 10, { value: E(1) })).to.be.revertedWith("bad interval");
    await expect(hw.connect(op).openWatch("x", 40 * DAY, { value: E(1) })).to.be.revertedWith("bad interval");
    await expect(hw.connect(op).openWatch("x", 6 * HOUR, { value: 1 })).to.be.revertedWith("bond too small");
  });

  it("lets only the operator pulse", async () => {
    const id = await openDefault();
    await expect(hw.connect(other).pulse(id)).to.be.revertedWith("not operator");
    await hw.connect(op).pulse(id);
    const w = await hw.getWatch(id);
    expect(w.pulseCount).to.equal(1);
  });

  it("refuses an alarm before the deadline", async () => {
    const id = await openDefault();
    await time.increase(5 * HOUR);
    expect(await hw.isOverdue(id)).to.equal(false);
    await expect(hw.connect(watcher).raiseAlarm(id)).to.be.revertedWith("not overdue");
  });

  it("slashes an overdue watch and pays the challenger a bounty", async () => {
    const id = await openDefault();
    await time.increase(6 * HOUR + GRACE + 60);
    expect(await hw.isOverdue(id)).to.equal(true);

    const before = await ethers.provider.getBalance(watcher.address);
    const tx = await hw.connect(watcher).raiseAlarm(id);
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    const after = await ethers.provider.getBalance(watcher.address);

    // 20% of 1 BOT slashed, half of that to the challenger.
    expect(after - before + gas).to.equal(E("0.1"));
    expect(await hw.accumulatedFees()).to.equal(E("0.1"));

    const w = await hw.getWatch(id);
    expect(w.bond).to.equal(E("0.8"));
    expect(w.strikes).to.equal(1);
    expect(w.status).to.equal(0); // still Active
    expect(await hw.bondedTotal()).to.equal(E("0.8"));
  });

  it("restarts the clock after a slash so the same lapse cannot be double-slashed", async () => {
    const id = await openDefault();
    await time.increase(6 * HOUR + GRACE + 60);
    await hw.connect(watcher).raiseAlarm(id);
    await expect(hw.connect(watcher).raiseAlarm(id)).to.be.revertedWith("not overdue");
  });

  it("marks a watch Breached once the bond falls below the floor", async () => {
    await hw.connect(owner).setParams(5000, 5000, E("0.6"));
    const id = await openDefault();
    await time.increase(6 * HOUR + GRACE + 60);
    await hw.connect(watcher).raiseAlarm(id);

    const w = await hw.getWatch(id);
    expect(w.status).to.equal(1); // Breached
    expect(w.bond).to.equal(E("0.5"));
    await expect(hw.connect(op).pulse(id)).to.be.revertedWith("not active");
  });

  it("revives a breached watch when the bond is topped back up", async () => {
    await hw.connect(owner).setParams(5000, 5000, E("0.6"));
    const id = await openDefault();
    await time.increase(6 * HOUR + GRACE + 60);
    await hw.connect(watcher).raiseAlarm(id);

    await hw.connect(op).topUpBond(id, { value: E("0.3") });
    const w = await hw.getWatch(id);
    expect(w.status).to.equal(0); // Active again
    expect(w.bond).to.equal(E("0.8"));
    await hw.connect(op).pulse(id);
  });

  it("closes only after the delay is served, and refunds the remaining bond", async () => {
    const id = await openDefault();
    await expect(hw.connect(op).closeWatch(id)).to.be.revertedWith("request first");

    await hw.connect(op).requestClose(id);
    await expect(hw.connect(op).closeWatch(id)).to.be.revertedWith("delay not served");

    // Serve the delay while keeping the watch healthy.
    await time.increase(5 * HOUR);
    await hw.connect(op).pulse(id);
    await time.increase(5 * HOUR);
    await hw.connect(op).pulse(id);
    await time.increase(5 * HOUR);
    await hw.connect(op).pulse(id);
    await time.increase(5 * HOUR);
    await hw.connect(op).pulse(id);
    await time.increase(5 * HOUR);

    const before = await ethers.provider.getBalance(op.address);
    const tx = await hw.connect(op).closeWatch(id);
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    const after = await ethers.provider.getBalance(op.address);

    expect(after - before + gas).to.equal(E(1));
    expect((await hw.getWatch(id)).status).to.equal(2); // Closed
    expect(await hw.bondedTotal()).to.equal(0);
  });

  it("refuses to close while overdue", async () => {
    const id = await openDefault();
    await hw.connect(op).requestClose(id);
    await time.increase(DAY + HOUR);
    await expect(hw.connect(op).closeWatch(id)).to.be.revertedWith("overdue");
  });

  it("lets a breached watch close immediately", async () => {
    await hw.connect(owner).setParams(5000, 5000, E("0.6"));
    const id = await openDefault();
    await time.increase(6 * HOUR + GRACE + 60);
    await hw.connect(watcher).raiseAlarm(id);
    await hw.connect(op).closeWatch(id);
    expect((await hw.getWatch(id)).status).to.equal(2);
  });

  it("keeps pulsing available while paused but freezes slashing", async () => {
    const id = await openDefault();
    await hw.connect(owner).pause();
    await hw.connect(op).pulse(id);
    await time.increase(6 * HOUR + GRACE + 60);
    await expect(hw.connect(watcher).raiseAlarm(id)).to.be.revertedWithCustomError(hw, "EnforcedPause");
    await expect(hw.connect(other).openWatch("x", 6 * HOUR, { value: E(1) })).to.be.revertedWithCustomError(
      hw,
      "EnforcedPause"
    );
  });

  it("gives every watch a fresh interval after an unpause", async () => {
    const id = await openDefault();
    await hw.connect(owner).pause();
    await time.increase(30 * DAY);
    await hw.connect(owner).unpause();

    // The pause itself must not make anyone slashable.
    expect(await hw.isOverdue(id)).to.equal(false);
    await expect(hw.connect(watcher).raiseAlarm(id)).to.be.revertedWith("not overdue");

    await time.increase(6 * HOUR + GRACE + 60);
    expect(await hw.isOverdue(id)).to.equal(true);
  });

  it("withdraws only accumulated fees, owner only", async () => {
    const id = await openDefault();
    await time.increase(6 * HOUR + GRACE + 60);
    await hw.connect(watcher).raiseAlarm(id);

    await expect(hw.connect(other).withdrawFees(other.address)).to.be.revertedWithCustomError(
      hw,
      "OwnableUnauthorizedAccount"
    );

    const fees = await hw.accumulatedFees();
    expect(fees).to.equal(E("0.1"));
    await expect(hw.connect(owner).withdrawFees(owner.address)).to.changeEtherBalance(hw, -fees);
    expect(await hw.accumulatedFees()).to.equal(0);

    // Bonds survive the sweep.
    expect(await ethers.provider.getBalance(await hw.getAddress())).to.equal(E("0.8"));
  });

  it("indexes watches by operator and returns them newest first", async () => {
    const a = await openDefault(op, 6 * HOUR, "1");
    const b = await openDefault(op, 12 * HOUR, "1");
    await openDefault(other, 6 * HOUR, "1");

    const mine = await hw.getWatchesByOperator(op.address);
    expect(mine.map(Number)).to.deep.equal([Number(a), Number(b)]);

    const recent = await hw.getRecent(2);
    expect(recent.map(Number)).to.deep.equal([2, 1]);
  });
});
