import { Controller } from "@hotwired/stimulus"

// The admin console's Light / Dark / System theme switch. The mode lives on
// <html data-theme-mode>; "system" follows the OS, including live changes
// while the page is open. The choice is saved through the existing /theme
// endpoint, the same one the app's theme picker uses.
const DARK_QUERY = "(prefers-color-scheme: dark)"

export default class extends Controller {
  static targets = ["option"]
  static values = { url: String }

  connect() {
    this.media = window.matchMedia(DARK_QUERY)
    this.onSystemChange = () => { if (this.mode === "system") this.apply() }
    this.media.addEventListener("change", this.onSystemChange)
    this.sync()
  }

  disconnect() {
    this.media?.removeEventListener("change", this.onSystemChange)
  }

  get mode() {
    return document.documentElement.dataset.themeMode || "light"
  }

  choose(event) {
    const mode = event.currentTarget.dataset.mode
    document.documentElement.dataset.themeMode = mode
    this.apply()
    this.sync()
    this.save(mode)
  }

  apply() {
    const dark = this.mode === "dark" || (this.mode === "system" && this.media.matches)
    document.documentElement.dataset.theme = dark ? "dark" : "light"
  }

  sync() {
    this.optionTargets.forEach((option) => option.setAttribute("aria-pressed", String(option.dataset.mode === this.mode)))
  }

  save(theme) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.urlValue || "/theme", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": token || "" },
      body: JSON.stringify({ theme })
    }).catch(() => {})
  }
}
