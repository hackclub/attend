import { Controller } from "@hotwired/stimulus"

// Plots the venues of one event series. Every threshold, colour and radius is
// decided server-side in Admin::SeriesHelper — this controller only places what
// it is handed, so the map and the table can never disagree about an event.
//
// Leaflet is imported dynamically: controllers are eager-loaded everywhere in
// the admin shell, and only this page needs the library.
//
// The map is a redundant view: the Events list on the same page already states
// every fact a marker encodes. That shapes two decisions here — a failed import
// degrades to a pointer at that list rather than a spinner or a silent void,
// and markers only ever need to be as good as the text beside them.
export default class extends Controller {
  static targets = ["map"]
  static values = { markers: Array }

  // Long enough that a warm CDN cache never flashes the placeholder, short
  // enough that a stalled request stops looking like a broken layout.
  static LOADING_DELAY_MS = 400

  async connect() {
    if (this.markersValue.length === 0) return

    this.scheduleLoadingPlaceholder()

    let L
    try {
      // leaflet-src.esm.js has named exports only — no default export.
      L = await import("leaflet")
    } catch {
      // Offline, blocked CDN, proxy interception. Previously this left a grey
      // rectangle forever, which on an ops dashboard reads as "no venues".
      this.renderUnavailable()
      return
    }

    if (!this.element.isConnected) return

    try {
      this.render(L)
    } catch {
      // A half-built map is worse than none, so drop it and say so plainly.
      this.teardown()
      this.renderUnavailable()
    }
  }

  disconnect() {
    this.teardown()
  }

  teardown() {
    this.cancelLoadingPlaceholder()
    this.resizeObserver?.disconnect()
    this.resizeObserver = null
    if (this.map) {
      this.map.remove()
      this.map = null
    }
  }

  render(L) {
    this.cancelLoadingPlaceholder()
    this.mapTarget.replaceChildren()

    this.map = L.map(this.mapTarget, {
      scrollWheelZoom: false,
      zoomControl: true,
      minZoom: 1,
      maxBounds: [[-85, -180], [85, 180]],
      maxBoundsViscosity: 1.0
    })

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
      maxZoom: 19,
      noWrap: true
    }).addTo(this.map)

    // The map shares a row with the funnel, so its height is settled by the
    // taller of the two. Without this the canvas keeps the size it was built
    // at and the tiles sit in the wrong place.
    this.resizeObserver = new ResizeObserver(() => {
      if (!this.map) return
      this.map.invalidateSize()
      this.fitToBounds()
    })
    this.resizeObserver.observe(this.mapTarget)

    this.bounds = []

    for (const marker of this.markersValue) {
      const size = marker.radius * 2

      const placed = L.marker([marker.lat, marker.lon], {
        title: marker.name,
        // Leaflet's default, but explicit because it is load-bearing here: it
        // is what puts tabindex and role="button" on the icon, so the popup's
        // link to the event dashboard is reachable without a pointer.
        keyboard: true,
        icon: L.divIcon({
          className: "",
          html: this.markerHtml(marker, size),
          iconSize: [size, size],
          iconAnchor: [marker.radius, marker.radius],
          popupAnchor: [0, -marker.radius - 2]
        })
      })
        .addTo(this.map)
        .bindPopup(this.popupElement(marker))

      this.decorateMarkerElement(placed.getElement(), marker)

      this.bounds.push([marker.lat, marker.lon])
    }

    this.fitToBounds()
  }

  fitToBounds() {
    if (!this.map || !this.bounds?.length) return

    if (this.bounds.length === 1) {
      this.map.setView(this.bounds[0], 5)
    } else {
      this.map.fitBounds(this.bounds, { padding: [32, 32], maxZoom: 7 })
    }
  }

  // The dot is the page's one colour-only signal: fill carries the share still
  // blocked and area carries the head count. Neither survives being read aloud,
  // so the icon gets the same facts as text.
  decorateMarkerElement(element, marker) {
    if (!element) return

    element.setAttribute("aria-label", this.markerLabel(marker))

    // Leaflet's focus ring is the browser default, which disappears against a
    // saturated dot. Applied here rather than in CSS because the marker sits on
    // OpenStreetMap tiles — always light, whatever the app theme — so the ring
    // is a fixed dark colour and cannot follow a theme token.
    element.addEventListener("focus", () => {
      element.style.outline = "2px solid #1f2d3d"
      element.style.outlineOffset = "2px"
    })
    element.addEventListener("blur", () => {
      element.style.outline = ""
      element.style.outlineOffset = ""
    })
  }

  markerLabel(marker) {
    return [marker.name, ...this.popupLines(marker), `${marker.percent}% cleared`].join(". ")
  }

  markerHtml(marker, size) {
    const dot = document.createElement("div")
    dot.className = "series-marker-dot"
    dot.style.cssText = `width:${size}px;height:${size}px;background:${marker.fill};`
    return dot.outerHTML
  }

  // Built with DOM APIs rather than string interpolation so an event name or
  // city is never parsed as HTML.
  popupElement(marker) {
    const container = document.createElement("div")

    const link = document.createElement("a")
    link.href = marker.url
    link.textContent = marker.name
    link.style.cssText = "font-weight:600;color:var(--text-strong);text-decoration:underline;"
    container.appendChild(link)

    for (const line of this.popupLines(marker)) {
      container.appendChild(document.createElement("br"))
      const span = document.createElement("span")
      span.style.color = "var(--text-soft)"
      span.textContent = line
      container.appendChild(span)
    }

    return container
  }

  popupLines(marker) {
    const lines = []
    if (marker.location) lines.push(marker.location)
    lines.push(marker.dates)

    if (marker.active === 0) {
      lines.push("No participants yet")
    } else if (marker.blocked === 0) {
      lines.push(`${marker.active} participants — all cleared`)
    } else {
      lines.push(`${marker.active} participants — ${marker.blocked} still blocked`)
    }

    return lines
  }

  scheduleLoadingPlaceholder() {
    this.loadingTimer = setTimeout(() => {
      this.loadingTimer = null
      if (this.map) return
      this.mapTarget.replaceChildren(this.messageElement("Loading map…"))
    }, this.constructor.LOADING_DELAY_MS)
  }

  cancelLoadingPlaceholder() {
    if (!this.loadingTimer) return
    clearTimeout(this.loadingTimer)
    this.loadingTimer = null
  }

  renderUnavailable() {
    if (!this.element.isConnected) return

    this.cancelLoadingPlaceholder()
    this.mapTarget.replaceChildren(this.messageElement(
      "The map couldn't load. Every event's location, dates and participant counts are in the Events list on this page."
    ))
  }

  // DOM APIs, no innerHTML: this text is fixed today, but the element is the
  // one place a marker's own strings would be tempting to splice in. Colour
  // comes from a theme token because, unlike the tiles, this box is painted by
  // the app and has to hold up in all nine themes.
  messageElement(text) {
    const wrapper = document.createElement("div")
    wrapper.setAttribute("role", "status")
    wrapper.style.cssText =
      "height:100%;display:flex;align-items:center;justify-content:center;padding:1.5rem;text-align:center;"

    const message = document.createElement("p")
    message.textContent = text
    // 0.875rem is DESIGN.md's body step: this is a message someone has to read,
    // not chart chrome, so it takes body size rather than a label size.
    message.style.cssText = "max-width:24rem;font-size:0.875rem;line-height:1.5;color:var(--text-soft);"
    wrapper.appendChild(message)

    return wrapper
  }
}
