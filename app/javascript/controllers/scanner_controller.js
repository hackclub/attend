import { Controller } from "@hotwired/stimulus"

// Mount point for the check-in scanner (app/javascript/scanner). The scanner
// is loaded on demand, so its modules stay off every other page.
export default class extends Controller {
  static values = { config: Object }

  connect() {
    this.mounted = true
    import("scanner/app").then(({ mountScanner }) => {
      if (this.mounted) this.teardown = mountScanner(this.element, this.configValue)
    }).catch((error) => {
      console.error("Scanner failed to load:", error)
      const status = document.getElementById("status-text")
      if (status) status.textContent = "Scanner failed to load - reload the page"
    })
  }

  disconnect() {
    this.mounted = false
    this.teardown?.()
    this.teardown = null
  }
}
