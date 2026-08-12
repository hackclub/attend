import { Controller } from "@hotwired/stimulus"

// applies the chosen theme instantly + persists it via /theme
export default class extends Controller {
  static values = { url: String }

  apply(event) {
    const theme = event.target.value
    document.documentElement.setAttribute("data-theme", theme)

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.urlValue || "/theme", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": token || ""
      },
      body: JSON.stringify({ theme })
    }).catch(() => {})
  }
}
