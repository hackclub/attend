import { Controller } from "@hotwired/stimulus"

// Re-renders countdown text every 30s without server round-trip.
// Each row may have:
//   data-arrivals-tick-target="countdown" data-time-iso=... data-status=... data-direction=...
export default class extends Controller {
  static targets = ["countdown"]

  connect() {
    this.tick()
    this.timer = setInterval(() => this.tick(), 30 * 1000)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  tick() {
    const now = Date.now()
    this.countdownTargets.forEach((el) => {
      const iso = el.dataset.timeIso
      if (!iso) return
      const status = el.dataset.status
      const direction = el.dataset.direction
      const inner = el.querySelector("span") || el

      // landed/picked_up labels are static; leave alone
      if (status === "landed" || status === "picked_up" || status === "cancelled" || status === "diverted") return

      const t = Date.parse(iso)
      if (Number.isNaN(t)) return
      const deltaMin = Math.round((t - now) / 60000)

      if (deltaMin > 0) {
        const verb = direction === "outbound" ? "departs" : "arrives"
        inner.textContent = deltaMin < 60
          ? `${verb} in ${deltaMin}m`
          : `${verb} in ${Math.floor(deltaMin / 60)}h ${deltaMin % 60}m`
        inner.className = deltaMin <= 30 ? "text-rose-600 font-medium" : "text-gray-500"
      } else if (deltaMin > -120) {
        inner.textContent = `${Math.abs(deltaMin)}m ago`
        inner.className = "text-gray-500"
      } else {
        inner.textContent = ""
      }
    })
  }
}
