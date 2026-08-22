import { Controller } from "@hotwired/stimulus"

// Safety net for the documents step. The embedded DocuSeal form fires a
// "completed" event that posts back and re-renders the page, but that event
// is the only thing moving the participant forward — and it doesn't always
// arrive (signed in the "open in a new tab" window, a dropped postMessage, a
// backgrounded tab). When it doesn't, the page sits on "0 of N signed" with a
// disabled Continue button until they reload by hand.
//
// So ask the server periodically instead. It answers with the set of consents
// whose participant portion is signed; the moment that differs from what this
// page was rendered with, reload and let the server decide what comes next.
// We only reload on a *change*, so a page rendered mid-signing stays put and
// nobody loses a partly-filled form.
export default class extends Controller {
  static values = {
    url: String,
    signedIds: Array,
    interval: { type: Number, default: 5000 }
  }

  connect() {
    this.rendered = this.normalise(this.signedIdsValue)
    this.timer = setInterval(() => this.check(), this.intervalValue)
  }

  disconnect() {
    this.stop()
  }

  stop() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }

  async check() {
    // No point polling for a tab nobody is looking at; it'll catch up when
    // they come back. A Turbo preview is a cached snapshot with the real
    // response already in flight — leave it alone rather than reloading over
    // a page that's about to be replaced anyway.
    if (document.hidden) return
    if (document.documentElement.hasAttribute("data-turbo-preview")) return

    let data
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      if (!response.ok) return
      data = await response.json()
    } catch (error) {
      // Offline, or the session went away and we got HTML back. Either way,
      // keep the interval running and try again.
      return
    }

    if (this.normalise(data.signed_consent_ids) === this.rendered) return

    this.stop()
    window.location.reload()
  }

  normalise(ids) {
    return (ids || []).map(String).sort().join(",")
  }
}
