import { Controller } from "@hotwired/stimulus"
import { WatchFrontier, MAX_RATE } from "utils/watch_frontier"

// Plays a training lesson's video without letting the learner skip ahead.
// Seeking back is fine; seeking past the furthest point genuinely watched
// (WatchFrontier) snaps back to it, and playback faster than 2x is pulled
// down. Progress goes to the server as heartbeats (TrainingVideoView caps it
// by real elapsed time, so this is the convenience layer, not the
// enforcement), and once the server says the video is done, the lesson's
// "gate" targets — the done button, the quiz — open.
//
// Sources: an uploaded file in a <video> (source "upload"), or a YouTube or
// Vimeo embed driven through the provider's player API.
const HEARTBEAT_MS = 5000
const TICK_MS = 250

export default class extends Controller {
  static targets = ["player", "gate", "locked", "status"]
  static values = {
    source: String,
    videoId: String,
    progressUrl: String,
    watched: Number,
    complete: Boolean
  }

  connect() {
    this.frontier = new WatchFrontier(this.watchedValue || 0, performance.now())
    this.duration = null
    if (this.completeValue) {
      this.unlock()
      return
    }
    this.lock()

    if (this.sourceValue === "upload") this.setupFile()
    else if (this.sourceValue === "youtube") this.setupYouTube()
    else if (this.sourceValue === "vimeo") this.setupVimeo()

    this.heartbeat = setInterval(() => this.report(), HEARTBEAT_MS)
    this.ticker = setInterval(() => this.tick(), TICK_MS)
  }

  disconnect() {
    clearInterval(this.heartbeat)
    clearInterval(this.ticker)
    this.youtube?.destroy?.()
    this.vimeo?.destroy?.()
  }

  // --- position bookkeeping, shared by every source ----------------------

  get furthest() {
    return this.frontier.furthest
  }

  // Each source implements state() → { position, playing, rate } (or null
  // before the player is ready) and seekTo(seconds).
  tick() {
    const state = this.state()
    if (!state) return
    const back = this.frontier.tick(state.position, { ...state, now: performance.now() })
    if (back !== null) this.seekTo(back)
  }

  // A seek or jump reported by the player: send it back at once rather than
  // waiting for the next tick.
  guard(position) {
    const back = this.frontier.check(position)
    if (back !== null) this.seekTo(back)
  }

  ended() {
    this.tick()
    this.frontier.finish(this.duration)
    this.report()
  }

  async report() {
    if (this.completeValue || !this.duration) return

    try {
      const response = await fetch(this.progressUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
        },
        body: JSON.stringify({ position: this.furthest, duration: this.duration })
      })
      if (!response.ok) return

      const data = await response.json()
      if (data.complete) {
        this.completeValue = true
        clearInterval(this.heartbeat)
        this.unlock()
      } else {
        this.showStatus(data.watched)
      }
    } catch {
      // A dropped heartbeat is harmless; the next one carries the same mark.
    }
  }

  lock() {
    this.gateTargets.forEach((el) => {
      el.disabled = true
      el.setAttribute("aria-disabled", "true")
    })
    this.lockedTargets.forEach((el) => el.classList.remove("hidden"))
  }

  unlock() {
    this.gateTargets.forEach((el) => {
      el.disabled = false
      el.removeAttribute("aria-disabled")
    })
    this.lockedTargets.forEach((el) => el.classList.add("hidden"))
    if (this.hasStatusTarget) this.statusTarget.textContent = "Video watched."
  }

  showStatus(watched) {
    if (!this.hasStatusTarget || !this.duration) return
    const percent = Math.min(100, Math.floor((watched / this.duration) * 100))
    this.statusTarget.textContent = `${percent}% watched`
  }

  // --- uploaded file -----------------------------------------------------

  setupFile() {
    const video = this.playerTarget
    const sync = () => { if (video.duration && isFinite(video.duration)) this.duration = video.duration }
    video.addEventListener("loadedmetadata", () => {
      sync()
      if (this.furthest > 0) video.currentTime = this.furthest
    })
    sync()

    this.state = () => ({ position: video.currentTime, playing: !video.paused && !video.seeking && !video.ended, rate: video.playbackRate })
    this.seekTo = (seconds) => { video.currentTime = seconds }

    for (const type of ["seeking", "seeked", "timeupdate"]) {
      video.addEventListener(type, () => this.guard(video.currentTime))
    }
    video.addEventListener("ratechange", () => {
      if (video.playbackRate > MAX_RATE) video.playbackRate = MAX_RATE
    })
    video.addEventListener("pause", () => this.report())
    video.addEventListener("ended", () => this.ended())
  }

  // --- YouTube -----------------------------------------------------------

  async setupYouTube() {
    this.state = () => null
    const YT = await loadYouTubeApi()
    this.youtube = new YT.Player(this.playerTarget, {
      host: "https://www.youtube-nocookie.com",
      videoId: this.videoIdValue,
      playerVars: { rel: 0, modestbranding: 1, playsinline: 1, start: Math.floor(this.furthest) },
      events: {
        onReady: () => {
          this.duration = this.youtube.getDuration() || null
          this.state = () => ({
            position: this.youtube.getCurrentTime(),
            playing: this.youtube.getPlayerState() === YT.PlayerState.PLAYING,
            rate: this.youtube.getPlaybackRate()
          })
          this.seekTo = (seconds) => this.youtube.seekTo(seconds, true)
        },
        onStateChange: (event) => {
          if (!this.duration) this.duration = this.youtube.getDuration() || null
          if (event.data === YT.PlayerState.ENDED) this.ended()
          if (event.data === YT.PlayerState.PAUSED) this.report()
        },
        onPlaybackRateChange: (event) => {
          if (event.data > MAX_RATE) this.youtube.setPlaybackRate(MAX_RATE)
        }
      }
    })
  }

  // --- Vimeo -------------------------------------------------------------

  async setupVimeo() {
    this.state = () => null
    const Vimeo = await loadScriptGlobal("https://player.vimeo.com/api/player.js", "Vimeo")
    this.vimeo = new Vimeo.Player(this.playerTarget, { id: Number(this.videoIdValue), responsive: true, dnt: true })
    this.vimeo.getDuration().then((duration) => { this.duration = duration })
    if (this.furthest > 0) this.vimeo.setCurrentTime(this.furthest).catch(() => {})

    // The SDK's getters are async, so the tick reads what its events last said.
    const live = { position: this.furthest, playing: false, rate: 1 }
    this.state = () => live
    this.seekTo = (seconds) => {
      live.position = seconds
      this.vimeo.setCurrentTime(seconds).catch(() => {})
    }

    this.vimeo.on("timeupdate", ({ seconds, duration }) => {
      this.duration ||= duration
      live.position = seconds
      this.guard(seconds)
    })
    this.vimeo.on("seeked", ({ seconds }) => {
      live.position = seconds
      this.guard(seconds)
    })
    this.vimeo.on("play", () => { live.playing = true })
    this.vimeo.on("pause", () => {
      live.playing = false
      this.report()
    })
    this.vimeo.on("playbackratechange", ({ playbackRate }) => {
      live.rate = playbackRate
      if (playbackRate > MAX_RATE) this.vimeo.setPlaybackRate(MAX_RATE).catch(() => {})
    })
    this.vimeo.on("ended", () => {
      live.playing = false
      this.ended()
    })
  }
}

function loadScriptGlobal(src, globalName) {
  if (window[globalName]) return Promise.resolve(window[globalName])

  return new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = src
    script.async = true
    script.onload = () => resolve(window[globalName])
    script.onerror = reject
    document.head.appendChild(script)
  })
}

// The IFrame API announces itself through a global callback rather than the
// script's load event.
let youTubeApi
function loadYouTubeApi() {
  if (window.YT?.Player) return Promise.resolve(window.YT)

  youTubeApi ||= new Promise((resolve, reject) => {
    const previous = window.onYouTubeIframeAPIReady
    window.onYouTubeIframeAPIReady = () => {
      previous?.()
      resolve(window.YT)
    }
    const script = document.createElement("script")
    script.src = "https://www.youtube.com/iframe_api"
    script.async = true
    script.onerror = reject
    document.head.appendChild(script)
  })
  return youTubeApi
}
