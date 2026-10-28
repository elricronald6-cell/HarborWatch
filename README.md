# HarborWatch

Bonded uptime pledges on BOT Chain.

An operator opens a watch over a service, posts a bond, and declares a check-in
interval. Every interval they must call `pulse()`. Miss the deadline (plus a
15 minute grace period) and **anyone** can call `raiseAlarm()`: a slice of the
bond is slashed, the caller keeps a bounty, and the rest becomes protocol fees.

No privileged party decides whether a service was up. The deadline is the judge.

## How it behaves

- **Slashing does not end a watch.** The bond shrinks by `slashBps` (20% by
  default) and the clock restarts, so a flaky operator bleeds rather than being
  cut off in one event.
- **Below the floor it is Breached.** Once the bond drops under `minBond` the
  watch is terminal — no more pulsing — but the operator can top the bond back
  up to revive it with a fresh interval.
- **Leaving takes 24 hours.** `requestClose` starts a delay; `closeWatch` is
  refused while the watch is overdue. An operator cannot see an outage coming
  and walk away with the whole bond.
- **An owner pause freezes slashing**, and every watch gets a full fresh
  interval after the unpause, so an admin pause can never cause a wave of
  slashes.

## Contract surface

| Call | Who | What it does |
|---|---|---|
| `openWatch(label, intervalSecs)` | anyone | Posts a bond and starts the clock. Interval 1h–30d, label ≤ 64 chars |
| `pulse(id)` | operator | Check in. Works while paused |
| `topUpBond(id)` | operator | Add bond; revives a Breached watch |
| `raiseAlarm(id)` | anyone | Slash an overdue watch, collect the bounty |
| `requestClose(id)` / `closeWatch(id)` | operator | 24h delay, then reclaim the remaining bond |
| `dueAt(id)`, `isOverdue(id)`, `secondsRemaining(id)` | view | The deadline and the time left |

`onlyOwner` covers pause/unpause, `setParams` (slash capped at 50%) and
`withdrawFees`, which is bounded by `accumulatedFees` and can never touch bonds.

## Build and deploy

```bash
npm install
npx hardhat test          # 15 tests
npm run deploy:testnet    # BOT Chain testnet, chain 968
npm run deploy:mainnet    # BOT Chain mainnet, chain 677
```

Create `.env` from `.env.example` with your `PRIVATE_KEY` first. The deploy
script prints the network name **and** the chain id, so the log is
self-evidencing.

After deploying, paste the address into `CONTRACT_ADDRESS` in
`frontend/index.html`. For mainnet also swap the five network values flagged in
the comment block directly above it, and set `label` to `"MAINNET"`.

## Frontend

Single file, no build step, ethers v6 from cdnjs. **Hyper-skeuomorphic** rack
hardware: brushed aluminium panels bolted into a rack with machined screws,
analog needle meters, LED lamps and a recessed phosphor readout. Each watch is
a 1U unit in the bay; the deadline is a bar meter etched into the panel and the
connect control is a physical toggle switch.

The page ends with the BOT Chain ecosystem footer, carrying links to
**botchain.ai** and the **block explorer**. The explorer href is read from the
`NETWORK` config at the top of the file, so the five-value mainnet swap updates
it too. No chain ID is printed anywhere on the page — these sites move from
testnet to mainnet, so a rendered chain ID would be wrong half the time — there is no second place to forget.
