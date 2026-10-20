import assert from "node:assert/strict"
import test from "node:test"

const { WatchFrontier } = await import(new URL("../../app/javascript/utils/watch_frontier.js", import.meta.url))

// Plays from `from` for `seconds` at `rate`, ticking every 250ms like the
// controller does. Returns the clock afterwards.
function play(frontier, { from, seconds, rate = 1, now = 0 }) {
  let position = from
  for (let t = 0.25; t <= seconds + 1e-9; t += 0.25) {
    position += 0.25 * rate
    now += 250
    const back = frontier.tick(position, { playing: true, rate, now })
    if (back !== null) position = back
  }
  return { position, now }
}

test("follows normal playback", () => {
  const frontier = new WatchFrontier(0, 0)
  const { position } = play(frontier, { from: 0, seconds: 10 })
  assert.equal(position, 10)
  assert.equal(frontier.furthest, 10)
})

test("sends a jump ahead straight back", () => {
  const frontier = new WatchFrontier(5, 0)
  assert.equal(frontier.check(11), 5)
  assert.equal(frontier.tick(11, { playing: true, rate: 1, now: 250 }), 5)
  assert.equal(frontier.furthest, 5)
})

// The bug Leo hit: dragging the scrubber is a run of small steps, each under
// the old 1.5s jump threshold, and each one moved the frontier up.
test("a slow drag of small steps can't ratchet the frontier", () => {
  const frontier = new WatchFrontier(1, 0)
  let position = 1
  let now = 0
  for (let step = 0; step < 40; step++) {
    position += 0.4
    now += 100
    const back = frontier.tick(position, { playing: false, rate: 1, now }) ?? frontier.check(position)
    if (back !== null) position = back
  }
  assert.equal(frontier.furthest, 1)
  assert.ok(position <= 1.5)
})

test("dragging while it plays earns only the time actually played", () => {
  const frontier = new WatchFrontier(0, 0)
  let position = 0
  let now = 0
  for (let step = 0; step < 20; step++) {
    position += 0.45
    now += 250
    const back = frontier.tick(position, { playing: true, rate: 1, now })
    if (back !== null) position = back
  }
  // 5 seconds of real time at 1x, plus the 10% drift allowance.
  assert.ok(frontier.furthest <= 5.5, `furthest was ${frontier.furthest}`)
})

test("paused time doesn't bank skippable time", () => {
  const frontier = new WatchFrontier(0, 0)
  let now = 0
  for (let i = 0; i < 240; i++) frontier.tick(3, { playing: false, rate: 1, now: (now += 250) })
  assert.equal(frontier.tick(30, { playing: true, rate: 1, now: now + 250 }), 0)
})

test("a stalled timer can't hand out a lump of time", () => {
  const frontier = new WatchFrontier(0, 0)
  assert.equal(frontier.tick(30, { playing: true, rate: 1, now: 60_000 }), 0)
  assert.ok(frontier.furthest <= 2.2)
})

test("rewatching an earlier part doesn't bank time to skip with", () => {
  const frontier = new WatchFrontier(0, 0)
  let { now } = play(frontier, { from: 0, seconds: 20 })
  ;({ now } = play(frontier, { from: 0, seconds: 10, now }))
  assert.equal(frontier.check(25), 20)
})

test("caps speed at 2x even when the player claims faster", () => {
  const frontier = new WatchFrontier(0, 0)
  play(frontier, { from: 0, seconds: 10, rate: 16 })
  assert.ok(frontier.furthest <= 2 * 10 * 1.1 + 1e-6, `furthest was ${frontier.furthest}`)
})

test("rounds up to the end only when it's genuinely reached", () => {
  const near = new WatchFrontier(59.4, 0)
  near.finish(60)
  assert.equal(near.furthest, 60)

  const far = new WatchFrontier(40, 0)
  far.finish(60)
  assert.equal(far.furthest, 40)
})
