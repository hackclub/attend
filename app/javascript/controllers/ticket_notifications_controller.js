import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggle", "notifications"]

  connect() {
    this.enabled = localStorage.getItem("ticketNotificationsEnabled") === "true"
    this.toggleTarget.checked = this.enabled

    if (this.enabled) {
      this.requestPermission()
    }

    this.observer = new MutationObserver((mutations) => {
      mutations.forEach((mutation) => {
        mutation.addedNodes.forEach((node) => {
          if (node.nodeType === Node.ELEMENT_NODE && node.dataset.ticketId) {
            this.notify(node.dataset)
          }
        })
      })
    })

    this.observer.observe(this.notificationsTarget, { childList: true })
  }

  disconnect() {
    if (this.observer) {
      this.observer.disconnect()
    }
  }

  toggleNotifications() {
    this.enabled = this.toggleTarget.checked
    localStorage.setItem("ticketNotificationsEnabled", this.enabled)

    if (this.enabled) {
      this.requestPermission()
    }
  }

  requestPermission() {
    if ("Notification" in window && Notification.permission === "default") {
      Notification.requestPermission()
    }
  }

  notify(data) {
    if (!this.enabled) return

    // Play sound
    this.playSound()

    // Show browser notification
    if ("Notification" in window && Notification.permission === "granted") {
      const channel = data.channel === "whatsapp" ? "WhatsApp" : "SMS"
      new Notification(`New ${channel} message`, {
        body: `From ${data.phone}`,
        icon: "/icon-192.png",
        tag: `ticket-${data.ticketId}`
      })
    }

    // Flash the title
    this.flashTitle()
  }

  playSound() {
    const audio = new Audio("data:audio/wav;base64,UklGRnoGAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQoGAACBhYqFbF1fdJivrJBhNjVgodDbq2EcBj+a2teleQkANa7v6ZpMAABL0ub/nEoAAE7V5v+RTAAAS9Hh/4tIAABEyNj/gkMAAD7Az/96PgAAOLjH/3I5AAAxr7//ajQAACqmtv9hLwAAI52u/1kqAAAdlKb/USYAABeLoP9JIQAAE4Ka/0EdAAAPeZT/OhkAAAt1j/80FgAACHGK/y8TAAAGZ4T/KhEAAAVigP8mDwAABF18/yMNAAADWHj/IA0AAAJUdf8eDAAAAVBy/xwLAAAAS27/GgsAAABHa/8YCgAAAENn/xcJAAAAP2T/FggAAAA7YP8VCAAAADZY/xQIAAAAM1j/EwcAAAAxVf8SBwAAAC9T/xIHAAAALVH/EQYAAAArT/8RBgAAACpN/xAGAAAAKEv/EAYAAAAnSf8PBgAAACZI/w8GAAAAJEX/DgYAAAAjRP8OBQAAACJv/w4FAAAAInH/DgUAAAAhdP8NBQAAACh2/w0FAAAAK3n/DQUAAABJ")
    audio.volume = 0.5
    audio.play().catch(() => {})
  }

  flashTitle() {
    const originalTitle = document.title
    let flashing = true
    let count = 0

    const flash = () => {
      if (!flashing || count > 10) {
        document.title = originalTitle
        return
      }
      document.title = count % 2 === 0 ? "🔔 New Message!" : originalTitle
      count++
      setTimeout(flash, 500)
    }

    flash()

    // Stop flashing on focus
    const stopFlash = () => {
      flashing = false
      document.title = originalTitle
      window.removeEventListener("focus", stopFlash)
    }
    window.addEventListener("focus", stopFlash)
  }
}
