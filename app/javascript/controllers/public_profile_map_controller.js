import { Controller } from "@hotwired/stimulus"

// Renders the map of attended events on public profiles. Leaflet is imported
// dynamically so the (CDN-hosted) library is only fetched on pages that
// actually render a map — controllers are eager-loaded everywhere else.
export default class extends Controller {
  static targets = ["map"]
  static values = { url: String }

  async connect() {
    // Markers come from a JSON endpoint instead of an HTML data attribute so
    // event names never pass through an HTML context.
    // leaflet-src.esm.js has named exports only — no default export.
    const [L, response] = await Promise.all([
      import("leaflet"),
      fetch(this.urlValue, { headers: { "Accept": "application/json" } })
    ])
    if (!this.element.isConnected || !response.ok) return
    const markers = await response.json()
    if (!this.element.isConnected) return

    this.map = L.map(this.mapTarget, {
      scrollWheelZoom: false,
      minZoom: 1,
      maxBounds: [[-85, -180], [85, 180]],
      maxBoundsViscosity: 1.0
    })

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
      maxZoom: 19,
      noWrap: true
    }).addTo(this.map)

    // The container's size depends on the responsive layout; without this the
    // canvas keeps its initial dimensions when the viewport changes. Re-fitting
    // the bounds also corrects a fit computed against a mid-layout size.
    this.resizeObserver = new ResizeObserver(() => {
      if (!this.map) return
      this.map.invalidateSize()
      this.fitToBounds()
    })
    this.resizeObserver.observe(this.mapTarget)

    this.bounds = []
    const bounds = this.bounds

    for (const marker of markers) {
      const icon = L.divIcon({
        className: "public-profile-event-marker",
        html: this.markerHtml(marker),
        iconSize: [40, 40],
        iconAnchor: [20, 20],
        popupAnchor: [0, -22]
      })

      L.marker([marker.lat, marker.lon], { icon, title: marker.name })
        .addTo(this.map)
        .bindPopup(this.popupElement(marker))

      bounds.push([marker.lat, marker.lon])
    }

    this.fitToBounds()
  }

  fitToBounds() {
    if (!this.map || !this.bounds?.length) return

    if (this.bounds.length === 1) {
      this.map.setView(this.bounds[0], 6)
    } else {
      this.map.fitBounds(this.bounds, { padding: [40, 40], maxZoom: 8 })
    }
  }

  disconnect() {
    this.resizeObserver?.disconnect()
    this.resizeObserver = null
    if (this.map) {
      this.map.remove()
      this.map = null
    }
  }

  markerHtml(marker) {
    const wrapper = document.createElement("div")
    wrapper.style.cssText =
      "width:40px;height:40px;border-radius:9999px;overflow:hidden;background:#ec3750;" +
      "border:2px solid white;box-shadow:0 2px 6px rgba(0,0,0,0.35);" +
      "display:flex;align-items:center;justify-content:center;color:white;font-weight:700;"

    if (marker.logo_url) {
      const img = document.createElement("img")
      img.src = marker.logo_url
      img.alt = ""
      img.style.cssText = "width:100%;height:100%;object-fit:cover;"
      wrapper.appendChild(img)
    } else {
      wrapper.textContent = (marker.name || "?").charAt(0).toUpperCase()
    }

    return wrapper.outerHTML
  }

  // Built via DOM APIs (not string interpolation) so event names/locations are
  // never parsed as HTML.
  popupElement(marker) {
    const container = document.createElement("div")

    const name = document.createElement("strong")
    name.textContent = marker.name
    container.appendChild(name)

    if (marker.location) {
      container.appendChild(document.createElement("br"))
      container.appendChild(document.createTextNode(marker.location))
    }

    return container
  }
}
