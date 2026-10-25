import { Controller } from "@hotwired/stimulus"

// The front door's map and country roll, wired together: every event with
// coordinates is a pin, and hovering, focusing or pressing a country lights the
// events its students went to. The counts and the pins come from the server
// (LandingStats) so this controller places and highlights, and decides nothing.
//
// Leaflet is imported dynamically — controllers are eager-loaded everywhere and
// only this page needs it. If it fails to load the roll still works on its own
// and the frame says so instead of sitting empty.
export default class extends Controller {
  static targets = ["map", "country", "status"]
  static values = { pins: Array }

  static LOADING_DELAY_MS = 400

  async connect() {
    this.markers = []
    this.selected = null

    if (this.pinsValue.length === 0) {
      this.renderMessage("No events on the map yet.")
      return
    }

    this.loadingTimer = setTimeout(() => {
      this.loadingTimer = null
      if (!this.map) this.renderMessage("Loading map…")
    }, this.constructor.LOADING_DELAY_MS)

    let L
    try {
      // leaflet-src.esm.js has named exports only — no default export.
      L = await import("leaflet")
    } catch {
      this.renderMessage("The map couldn't load. The numbers above are still live.")
      return
    }
    if (!this.element.isConnected) return

    try {
      this.render(L)
    } catch {
      this.teardown()
      this.renderMessage("The map couldn't load. The numbers above are still live.")
    }
  }

  disconnect() {
    this.teardown()
  }

  teardown() {
    if (this.loadingTimer) clearTimeout(this.loadingTimer)
    this.loadingTimer = null
    this.resizeObserver?.disconnect()
    this.resizeObserver = null
    if (this.map) {
      this.map.remove()
      this.map = null
    }
  }

  render(L) {
    if (this.loadingTimer) clearTimeout(this.loadingTimer)
    this.loadingTimer = null
    this.mapTarget.replaceChildren()

    this.map = L.map(this.mapTarget, {
      scrollWheelZoom: false,
      zoomControl: false,
      attributionControl: true,
      minZoom: 1,
      // Fractional zoom lets fitBounds fill the frame with the pins' own
      // extent instead of snapping out a level and showing polar ocean.
      zoomSnap: 0.25,
      maxBounds: [[-85, -180], [85, 180]],
      maxBoundsViscosity: 1.0
    })

    // On a phone the frame is 224px tall and full width; a zoom control there
    // sits on top of Oceania. Pinch and double-tap still zoom.
    if (window.matchMedia("(min-width: 640px)").matches) {
      L.control.zoom({ position: "topright" }).addTo(this.map)
    }

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      maxZoom: 19,
      noWrap: true
    }).addTo(this.map)

    this.resizeObserver = new ResizeObserver(() => {
      if (!this.map) return
      this.map.invalidateSize()
      this.fitToBounds()
    })
    this.resizeObserver.observe(this.mapTarget)

    const total = this.pinsValue.length
    this.bounds = []

    this.pinsValue.forEach((pin, index) => {
      const size = pin.state === "upcoming" ? 10 : 15
      const marker = L.marker([pin.lat, pin.lon], {
        title: pin.name,
        keyboard: true,
        // Three hundred announced cities would bury the events that happened;
        // what happened sits on top of what is planned.
        zIndexOffset: pin.state === "upcoming" ? 0 : 1000,
        icon: L.divIcon({
          className: "",
          html: this.pinHtml(pin, index, total),
          iconSize: [size, size],
          iconAnchor: [size / 2, size / 2],
          popupAnchor: [0, -size / 2 - 2]
        })
      })
        .addTo(this.map)
        .bindPopup(this.popupElement(pin))

      marker.getElement()?.setAttribute("aria-label", this.pinLabel(pin))
      this.markers.push(marker)
      this.bounds.push([pin.lat, pin.lon])
    })

    this.fitToBounds()
  }

  fitToBounds() {
    if (!this.map || !this.bounds?.length) return
    if (this.bounds.length === 1) {
      this.map.setView(this.bounds[0], 4)
    } else {
      this.map.fitBounds(this.bounds, { padding: [10, 10], maxZoom: 5 })
    }
  }

  // Pins arrive in date order, so the one entrance animation plays through the
  // history of events rather than popping all at once: 300ms of stagger plus a
  // 300ms pop, so the whole roll-in lands inside 600ms. Past events get it;
  // upcoming ones are already "unlit" and simply appear.
  pinHtml(pin, index, total) {
    const dot = document.createElement("span")
    dot.className = `landing-pin landing-pin--${pin.state}`
    if (pin.state !== "upcoming") {
      dot.style.animationDelay = `${Math.round((index / total) * 300)}ms`
    }
    return dot.outerHTML
  }

  pinLabel(pin) {
    return [pin.name, pin.location, pin.dates, this.headcountLine(pin)].filter(Boolean).join(". ")
  }

  headcountLine(pin) {
    if (pin.state === "upcoming") return "Upcoming"
    if (pin.state === "live") return `Happening now · ${pin.students} students`
    return `${pin.students} students`
  }

  // DOM APIs rather than string interpolation so an event name is never parsed
  // as HTML.
  popupElement(pin) {
    const container = document.createElement("div")
    const name = document.createElement("strong")
    name.textContent = pin.name
    name.style.cssText = "display:block;font-weight:600;color:var(--text-strong);"
    container.appendChild(name)

    for (const line of [pin.location, pin.dates, this.headcountLine(pin)]) {
      if (!line) continue
      const span = document.createElement("span")
      span.textContent = line
      span.style.cssText = "display:block;color:var(--text-soft);"
      container.appendChild(span)
    }
    return container
  }

  // --- Country roll ---------------------------------------------------------

  preview(event) {
    if (this.selected) return
    this.light(this.pinIndexes(event.currentTarget))
  }

  unpreview() {
    if (this.selected) return
    this.light(null)
  }

  // Pressing a country keeps its events lit until it is pressed again, so a
  // keyboard or touch visitor gets the same reading a hover gives a mouse.
  toggle(event) {
    const button = event.currentTarget
    if (this.selected === button) {
      this.selected = null
      button.setAttribute("aria-pressed", "false")
      this.light(null)
      return
    }
    this.selected?.setAttribute("aria-pressed", "false")
    this.selected = button
    button.setAttribute("aria-pressed", "true")
    this.light(this.pinIndexes(button))
  }

  pinIndexes(button) {
    const raw = button.dataset.pins
    return raw ? raw.split(",").map(Number) : []
  }

  light(indexes) {
    if (!this.map) return
    const lit = new Set(indexes || [])
    this.mapTarget.classList.toggle("is-dimmed", indexes !== null)
    this.markers.forEach((marker, i) => {
      marker.getElement()?.querySelector(".landing-pin")?.classList.toggle("is-lit", lit.has(i))
    })
  }

  renderMessage(text) {
    if (!this.element.isConnected) return
    if (this.loadingTimer) clearTimeout(this.loadingTimer)
    this.loadingTimer = null

    const wrapper = document.createElement("div")
    wrapper.setAttribute("role", "status")
    wrapper.className = "landing-map-message"
    const message = document.createElement("p")
    message.textContent = text
    wrapper.appendChild(message)
    this.mapTarget.replaceChildren(wrapper)
  }
}
