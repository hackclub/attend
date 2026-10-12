import { Controller } from "@hotwired/stimulus"

// applies the chosen theme instantly + persists it via /theme
export default class extends Controller {
  static values = { url: String }

  apply(event) {
    const theme = event.target.value
    document.documentElement.setAttribute("data-theme", this.displayTheme(theme))

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

  // The admin console only has light and dark (see ConsoleHelper), so a
  // picked theme is collapsed to one of them there, the same way the server
  // renders it on the next load.
  displayTheme(theme) {
    const root = document.documentElement
    if (!root.classList.contains("cs-console")) return theme

    let lightThemes = ["light"]
    try { lightThemes = JSON.parse(root.dataset.consoleLightThemes || "[\"light\"]") } catch (e) {}
    return lightThemes.includes(theme) ? "light" : "dark"
  }
}
