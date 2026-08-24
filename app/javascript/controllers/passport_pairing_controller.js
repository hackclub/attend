import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["statusDot", "statusText", "connectButton", "pairButton", "progress"]
  static values = { createUrl: String }

  connect() {
    this.bridge = null
    this.pendingPassport = null
    this.verifying = false
  }

  disconnect() {
    this.bridge?.close()
    this.clearPendingPassport()
  }

  toggleConnection() {
    if (this.bridge?.readyState === WebSocket.OPEN) {
      this.bridge.close()
      return
    }

    this.setConnectionStatus("connecting", "Connecting…")

    try {
      this.bridge = new WebSocket("ws://localhost:9876")
      this.bridge.onopen = () => this.setConnectionStatus("connected", "Ready to pair")
      this.bridge.onclose = () => {
        this.bridge = null
        this.setConnectionStatus("disconnected", "Not connected")
      }
      this.bridge.onerror = () => this.setConnectionStatus("error", "Bridge not running")
      this.bridge.onmessage = event => this.handleBridgeMessage(JSON.parse(event.data))
    } catch (_error) {
      this.bridge = null
      this.setConnectionStatus("error", "Connection failed")
    }
  }

  async pair() {
    if (this.bridge?.readyState !== WebSocket.OPEN) {
      this.setProgress("Connect the NFC bridge first.", true)
      return
    }

    this.pairButtonTarget.disabled = true
    this.setProgress("Preparing passport…")

    try {
      const response = await fetch(this.createUrlValue, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken
        }
      })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || "Could not prepare passport")

      this.pendingPassport = {
        token: result.token,
        confirmUrl: result.confirm_url
      }
      this.verifying = false
      this.setProgress(`Tap the ${result.serial_number} passport to write it.`)
      this.bridge.send(JSON.stringify({ action: "write", attend_token: result.token }))
    } catch (error) {
      this.clearPendingPassport()
      this.setProgress(error.message, true)
      this.pairButtonTarget.disabled = false
    }
  }

  handleBridgeMessage(data) {
    if (!this.pendingPassport) return

    if (data.type === "write_pending") {
      this.setProgress("Tap the passport to the reader…")
    } else if (data.type === "write_result") {
      if (data.success) {
        this.verifying = true
        this.setProgress("Written. Tap the passport again to verify it.")
      } else {
        this.clearPendingPassport()
        this.setProgress(`Write failed: ${data.error || "Unknown error"}`, true)
        this.pairButtonTarget.disabled = false
      }
    } else if (data.type === "tag_read" && this.verifying) {
      this.verifyRead(data.tag?.attendToken)
    }
  }

  async verifyRead(readToken) {
    if (readToken !== this.pendingPassport.token) {
      this.setProgress("Passport token mismatch. Tap it again to retry.", true)
      return
    }

    const pendingPassport = this.pendingPassport
    this.setProgress("Confirming passport…")

    try {
      const response = await fetch(pendingPassport.confirmUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken
        },
        body: JSON.stringify({ passport_token: pendingPassport.token })
      })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || "Could not confirm passport")

      this.clearPendingPassport()
      this.setProgress(`Passport ${result.serial_number} paired.`)
      window.setTimeout(() => window.location.reload(), 800)
    } catch (error) {
      this.clearPendingPassport()
      this.setProgress(error.message, true)
      this.pairButtonTarget.disabled = false
    }
  }

  setConnectionStatus(status, message) {
    const colors = {
      connected: "bg-green-500",
      connecting: "bg-yellow-500 animate-pulse",
      error: "bg-red-500",
      disconnected: "bg-gray-400"
    }

    this.statusDotTarget.className = `size-2 rounded-full ${colors[status]}`
    this.statusTextTarget.textContent = message
    this.connectButtonTarget.textContent = status === "connected" ? "Disconnect" : "Connect"
    this.pairButtonTarget.disabled = status !== "connected"
  }

  setProgress(message, isError = false) {
    this.progressTarget.textContent = message
    this.progressTarget.classList.toggle("text-red-600", isError)
    this.progressTarget.classList.toggle("text-gray-600", !isError)
  }

  clearPendingPassport() {
    this.pendingPassport = null
    this.verifying = false
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }
}
