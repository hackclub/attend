// The furthest point of a training video someone has genuinely watched.
//
// The frontier only moves forward with real playing time, at the playback
// rate (capped at MAX_RATE). It's driven by a steady tick rather than by the
// player's own events, so nothing the learner does to the scrubber can move
// it: paused time earns nothing, a drag earns nothing however small its steps,
// and rewatching an earlier part doesn't bank time to skip with later.
//
//   const frontier = new WatchFrontier(alreadyWatched, performance.now())
//   frontier.tick(position, { playing, rate, now })  // every ~250ms
//   frontier.check(position)                         // on seeking/timeupdate
//
// Both return a position to send the player back to, or null.
export const MAX_RATE = 2

// How far past the frontier the playhead may sit before it's sent back: covers
// the gap between ticks and keyframe-aligned seeks, and nothing more.
const TOLERANCE = 0.5

// Media clock vs. timer jitter, as a fraction of the time earned.
const DRIFT = 1.1

// The most one tick can earn. Ticks come every ~250ms, or ~1s in a throttled
// background tab; a longer gap means the timer stalled, and must not turn into
// a lump of skippable time.
const MAX_TICK_SECONDS = 2

export class WatchFrontier {
  constructor(furthest = 0, now = 0) {
    this.furthest = furthest
    this.lastTick = now
  }

  tick(position, { playing, rate = 1, now }) {
    const elapsed = Math.min(Math.max((now - this.lastTick) / 1000, 0), MAX_TICK_SECONDS)
    this.lastTick = now

    const earned = playing ? elapsed * Math.min(Math.max(rate, 0), MAX_RATE) * DRIFT : 0

    // Further than this tick could have played to: it's a skip, so nothing is
    // earned and the playhead goes back.
    if (position > this.furthest + earned + TOLERANCE) return this.furthest

    if (position > this.furthest) this.furthest = Math.min(position, this.furthest + earned)
    return this.check(position)
  }

  check(position) {
    return position > this.furthest + TOLERANCE ? this.furthest : null
  }

  // At the end of the video, the last stretch may not have been ticked yet.
  finish(duration) {
    if (duration && this.furthest >= duration - TOLERANCE * 2) this.furthest = duration
  }
}
