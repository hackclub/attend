import { Controller } from "@hotwired/stimulus"

// Filters the arrivals/departures board by status chip, search text, airport, and terminal.
// All client-side over data-* attrs on each <li data-airport-filter-target="journey">.
export default class extends Controller {
  static targets = [
    "journey", "airportSection", "airportCount",
    "chip", "search", "airportSelect", "terminalSelect", "hideLandedToggle"
  ]
  static values = { tab: String }

  connect() {
    const params = new URLSearchParams(window.location.search)
    this.state = {
      status:   params.get("status")   || "all",
      q:        params.get("q")        || "",
      airport:  params.get("airport")  || "",
      terminal: params.get("terminal") || "",
      hideLanded: params.get("hide_landed") === "1"
    }
    if (this.hasSearchTarget) this.searchTarget.value = this.state.q
    if (this.hasAirportSelectTarget) this.airportSelectTarget.value = this.state.airport
    if (this.hasTerminalSelectTarget) this.terminalSelectTarget.value = this.state.terminal
    this.syncChipUI()
    this.syncHideLandedUI()
    this.apply()
  }

  toggleHideLanded() {
    this.state.hideLanded = !this.state.hideLanded
    this.syncHideLandedUI()
    this.apply()
  }

  setStatus(event) {
    this.state.status = event.currentTarget.dataset.status
    this.syncChipUI()
    this.apply()
  }

  search(event) {
    this.state.q = event.currentTarget.value.trim().toLowerCase()
    this.apply()
  }

  setAirport(event) {
    this.state.airport = event.currentTarget.value
    this.apply()
  }

  setTerminal(event) {
    this.state.terminal = event.currentTarget.value
    this.apply()
  }

  reset() {
    this.state = { status: "all", q: "", airport: "", terminal: "", hideLanded: false }
    if (this.hasSearchTarget) this.searchTarget.value = ""
    if (this.hasAirportSelectTarget) this.airportSelectTarget.value = ""
    if (this.hasTerminalSelectTarget) this.terminalSelectTarget.value = ""
    this.syncChipUI()
    this.syncHideLandedUI()
    this.apply()
  }

  syncHideLandedUI() {
    if (!this.hasHideLandedToggleTarget) return
    const toggle = this.hideLandedToggleTarget
    toggle.className = this.state.hideLanded ? toggle.dataset.activeClass : toggle.dataset.inactiveClass
    toggle.setAttribute("aria-pressed", this.state.hideLanded ? "true" : "false")
  }

  syncChipUI() {
    if (!this.hasChipTarget) return
    this.chipTargets.forEach((chip) => {
      const active = chip.dataset.status === this.state.status
      chip.className = active ? chip.dataset.activeClass : chip.dataset.inactiveClass
    })
  }

  apply() {
    this.journeyTargets.forEach((row) => {
      row.style.display = this.matches(row) ? "" : "none"
    })
    if (this.hasAirportSectionTarget) {
      this.airportSectionTargets.forEach((section) => {
        const visible = Array.from(section.querySelectorAll("[data-airport-filter-target='journey']"))
          .filter((j) => j.style.display !== "none")
        section.style.display = visible.length > 0 ? "" : "none"
        const counter = section.querySelector("[data-airport-filter-target='airportCount']")
        if (counter) counter.textContent = visible.length
      })
    }
    this.persistState()
  }

  matches(row) {
    const ds = row.dataset
    if (this.state.airport && ds.airport !== this.state.airport) return false
    if (this.state.terminal && ds.terminal !== this.state.terminal) return false
    if (this.state.q && !(ds.search || "").includes(this.state.q)) return false
    if (this.state.hideLanded && (ds.status === "landed" || ds.status === "picked_up")) return false

    switch (this.state.status) {
      case "all": return true
      case "alerts": return ds.isAlert === "1"
      case "ums":    return ds.isUm === "1"
      case "arriving_now": return ds.arrivingNow === "1"
      case "landed":    return ds.status === "landed"
      case "in_flight": return ds.status === "in_flight"
      case "scheduled": return ds.status === "scheduled"
      case "picked_up": return ds.status === "picked_up"
      default: return true
    }
  }

  persistState() {
    const url = new URL(window.location)
    const params = url.searchParams
    const upsert = (k, v) => v ? params.set(k, v) : params.delete(k)
    upsert("status",   this.state.status === "all" ? "" : this.state.status)
    upsert("q",        this.state.q)
    upsert("airport",  this.state.airport)
    upsert("terminal", this.state.terminal)
    upsert("hide_landed", this.state.hideLanded ? "1" : "")
    window.history.replaceState({}, "", url)
  }
}
