import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    url: String,
    reloadOnSuccess: { type: Boolean, default: true }
  }

  async refresh(event) {
    event.preventDefault()
    const btn = event.currentTarget
    if (btn.disabled) return

    const originalText = btn.textContent
    btn.disabled = true
    btn.textContent = "Refreshing…"

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || ''

    try {
      const res = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken,
          "X-Requested-With": "XMLHttpRequest"
        },
        credentials: "same-origin"
      })

      const data = await res.json().catch(() => ({}))

      if (res.ok && data.success) {
        btn.textContent = "Refreshed ✓"
        if (this.reloadOnSuccessValue) {
          setTimeout(() => window.location.reload(), 400)
        } else {
          setTimeout(() => {
            btn.textContent = originalText
            btn.disabled = false
          }, 1500)
        }
      } else {
        const msg = data.error || `Error (${res.status})`
        btn.textContent = "Failed"
        btn.title = msg
        console.error("[flight-leg-refresh]", msg)
        setTimeout(() => {
          btn.textContent = originalText
          btn.disabled = false
        }, 2000)
      }
    } catch (err) {
      console.error("[flight-leg-refresh]", err)
      btn.textContent = "Failed"
      setTimeout(() => {
        btn.textContent = originalText
        btn.disabled = false
      }, 2000)
    }
  }
}
