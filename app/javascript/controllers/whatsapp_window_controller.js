import { Controller } from "@hotwired/stimulus"

// WhatsApp only accepts freeform replies for 24 hours after the contact's last
// inbound message; outside that window Meta rejects the send (Twilio 63016).
// The server renders the state on page load — this keeps it honest while the
// page stays open, since the window can lapse and a new inbound reopens it.
export default class extends Controller {
  static targets = ["closed", "open", "countdown", "input", "submit"]
  static values = { expiresAt: String }

  connect() {
    this.render()
    this.timer = setInterval(() => this.render(), 30000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  // Announced by whatsapp-window-ping when an inbound message shows up.
  inboundReceived(event) {
    const receivedAt = new Date(event.detail.at)
    if (isNaN(receivedAt)) return

    const expiresAt = new Date(receivedAt.getTime() + 24 * 60 * 60 * 1000)
    if (expiresAt <= this.expiresAt()) return

    this.expiresAtValue = expiresAt.toISOString()
    this.render()
  }

  render() {
    const expiresAt = this.expiresAt()
    const open = expiresAt !== null && expiresAt > new Date()

    this.closedTargets.forEach((el) => el.classList.toggle("hidden", open))
    this.openTargets.forEach((el) => el.classList.toggle("hidden", !open))
    this.inputTargets.forEach((el) => { el.disabled = !open })
    this.submitTargets.forEach((el) => { el.disabled = !open })

    if (open) {
      this.countdownTargets.forEach((el) => { el.textContent = this.remaining(expiresAt) })
    }
  }

  expiresAt() {
    if (!this.expiresAtValue) return null

    const parsed = new Date(this.expiresAtValue)
    return isNaN(parsed) ? null : parsed
  }

  remaining(expiresAt) {
    const minutes = Math.max(0, Math.round((expiresAt - new Date()) / 60000))
    if (minutes < 60) return `${minutes} min`

    const hours = Math.floor(minutes / 60)
    const rest = minutes % 60
    return rest === 0 ? `${hours} hr` : `${hours} hr ${rest} min`
  }
}
