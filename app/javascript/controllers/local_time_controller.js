import { Controller } from "@hotwired/stimulus"

// Rewrites server-rendered timestamps into the viewer's local time zone.
// Server-rendered text remains as a fallback when JS is disabled.
export default class extends Controller {
  static targets = ["date", "time"]
  static values = { datetime: String }

  connect() {
    const parsed = new Date(this.datetimeValue)
    if (isNaN(parsed)) return

    if (this.hasDateTarget) {
      this.dateTarget.textContent = parsed.toLocaleDateString(undefined, {
        month: "short", day: "numeric", year: "numeric"
      })
    }
    if (this.hasTimeTarget) {
      this.timeTarget.textContent = parsed.toLocaleTimeString(undefined, {
        hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit"
      })
    }
  }
}
