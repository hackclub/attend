import { Controller } from "@hotwired/stimulus"

// Admin console: rewrites a server-rendered Cloudscape absolute timestamp
// into the viewer's own time zone, keeping the Cloudscape format:
// "January 31, 2010, 14:32 (UTC+3:30)". Put it on a <time> element whose
// datetime attribute holds an ISO 8601 value. The server-rendered text
// stays as the fallback without JavaScript.
export default class extends Controller {
  connect() {
    const parsed = new Date(this.element.getAttribute("datetime"))
    if (isNaN(parsed)) return

    const date = parsed.toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" })
    const hours = String(parsed.getHours()).padStart(2, "0")
    const minutes = String(parsed.getMinutes()).padStart(2, "0")
    this.element.textContent = `${date}, ${hours}:${minutes} (${this.offset(parsed)})`
  }

  // "UTC+3:30", "UTC-5:00", "UTC+0:00".
  offset(date) {
    const total = -date.getTimezoneOffset()
    const sign = total < 0 ? "-" : "+"
    const abs = Math.abs(total)
    return `UTC${sign}${Math.floor(abs / 60)}:${String(abs % 60).padStart(2, "0")}`
  }
}
