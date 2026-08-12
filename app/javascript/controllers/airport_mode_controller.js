import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["map"]
  static values = {
    flights: Array,
    eventLocation: Object,
    eventName: String,
    markUrl: String,
    unmarkUrl: String
  }

  connect() {
    this.initMap()
  }

  disconnect() {
    if (this.map) {
      this.map.remove()
      this.map = null
    }
  }

  initMap() {
    if (typeof L === "undefined") {
      console.error("Leaflet not loaded")
      setTimeout(() => this.initMap(), 100)
      return
    }

    const mapContainer = this.mapTarget
    if (!mapContainer) return

    this.map = L.map(mapContainer).setView([45, 10], 4)

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      maxZoom: 19
    }).addTo(this.map)

    const flights = this.flightsValue || []
    const eventLocation = this.eventLocationValue
    const eventName = this.eventNameValue

    const allCoords = []

    if (eventLocation && eventLocation.lat && eventLocation.lon) {
      const venueIcon = L.divIcon({
        className: "venue-marker",
        html: '<div style="width: 20px; height: 20px; background: #EF4444; transform: rotate(45deg); border: 2px solid white; box-shadow: 0 2px 4px rgba(0,0,0,0.3); clip-path: polygon(50% 0%, 100% 50%, 50% 100%, 0% 50%);"></div>',
        iconSize: [20, 20],
        iconAnchor: [10, 10]
      })

      L.marker([eventLocation.lat, eventLocation.lon], { icon: venueIcon })
        .addTo(this.map)
        .bindPopup(`<strong>${eventName}</strong><br>Event Venue`)

      allCoords.push([eventLocation.lat, eventLocation.lon])
    }

    flights.forEach((flight) => {
      if (!flight.departure_coordinates || !flight.arrival_coordinates) return

      const depCoords = [flight.departure_coordinates.lat, flight.departure_coordinates.lon]
      const arrCoords = [flight.arrival_coordinates.lat, flight.arrival_coordinates.lon]

      allCoords.push(depCoords)
      allCoords.push(arrCoords)

      const isInbound = flight.direction === "inbound" || flight.direction === ":inbound"
      const lineColor = isInbound ? "#3B82F6" : "#A855F7"

      L.polyline([depCoords, arrCoords], {
        color: lineColor,
        weight: 2,
        opacity: 0.4,
        dashArray: "5, 10"
      }).addTo(this.map)

      if (flight.status?.includes?.("Arrived") && arrCoords) {
        const arrivedIcon = L.divIcon({
          className: "plane-marker",
          html: '<div style="width: 10px; height: 10px; border-radius: 50%; background: #22C55E; border: 2px solid white; box-shadow: 0 2px 4px rgba(0,0,0,0.3);"></div>',
          iconSize: [10, 10],
          iconAnchor: [5, 5]
        })

        L.marker(arrCoords, { icon: arrivedIcon })
          .addTo(this.map)
          .bindPopup(this.buildFlightPopup(flight))
      }

      if (flight.status === "Scheduled" && depCoords) {
        const scheduledIcon = L.divIcon({
          className: "plane-marker",
          html: '<div style="width: 8px; height: 8px; border-radius: 50%; background: #9CA3AF; border: 2px solid white; box-shadow: 0 2px 4px rgba(0,0,0,0.3);"></div>',
          iconSize: [8, 8],
          iconAnchor: [4, 4]
        })

        L.marker(depCoords, { icon: scheduledIcon })
          .addTo(this.map)
          .bindPopup(this.buildFlightPopup(flight))
      }
    })

    if (allCoords.length > 0) {
      this.map.fitBounds(allCoords, { padding: [30, 30] })
    } else {
      this.map.setView([30, 0], 2)
    }

    setTimeout(() => {
      this.map.invalidateSize()
    }, 100)
  }

  buildFlightPopup(flight) {
    let html = `<div style="min-width: 160px;">`
    html += `<strong>${flight.flight_code}</strong>`

    if (flight.status_label) {
      html += ` <span style="font-size: 11px; color: #666;">${flight.status_label}</span>`
    }

    html += `<br><span style="color: #666; font-size: 12px;">${flight.participant_name}</span>`

    html += `<div style="margin-top: 6px; font-size: 12px;">`
    html += `${flight.departure_airport} → ${flight.arrival_airport}`
    html += `</div>`

    if (flight.predicted_arrival || flight.scheduled_arrival) {
      const time = flight.predicted_arrival || flight.scheduled_arrival
      const label = flight.status?.includes?.("Arrived") ? "Arrived" : "ETA"
      try {
        const formatted = new Date(time).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
        html += `<div style="margin-top: 4px; font-size: 11px; color: #666;">${label}: ${formatted}</div>`
      } catch (e) {
        // ignore
      }
    }

    html += `</div>`
    return html
  }
}
