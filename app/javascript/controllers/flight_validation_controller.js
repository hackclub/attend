import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["flightCode", "departureDate", "departureAirport", "arrivalAirport", "departureTimeHidden", "arrivalTimeHidden", "timesDisplay", "timesText", "status", "flightPicker"]
  static values = {
    validateUrl: { type: String, default: "/api/v1/travel/validate_flight" }
  }

  connect() {
    this.debounceTimer = null
    this.abortController = null
    this.currentFlights = []
    this.initializeDateFields()
    this.validatePrefilledFlight()
  }

  initializeDateFields() {
    if (this.hasDepartureDateTarget && this.departureDateTarget.value) {
      this.updateDateFromPicker()
    }
  }

  validatePrefilledFlight() {
    if (this.hasFlightCodeTarget && this.flightCodeTarget.value.trim().length >= 3) {
      this.performValidation()
    }
  }

  disconnect() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    if (this.abortController) this.abortController.abort()
  }

  validateFlight() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)

    this.debounceTimer = setTimeout(() => {
      this.performValidation()
    }, 500)
  }

  async performValidation() {
    const flightCode = this.flightCodeTarget.value.trim()
    const departureDate = this.hasDepartureDateTarget ? this.departureDateTarget.value : null

    if (!flightCode || flightCode.length < 3) {
      this.clearStatus()
      return
    }

    if (this.abortController) this.abortController.abort()
    this.abortController = new AbortController()

    this.showStatus("Validating flight...", "loading")

    try {
      const response = await fetch(this.validateUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
        },
        body: JSON.stringify({
          flight_code: flightCode,
          departure_date: departureDate ? departureDate.split("T")[0] : null
        }),
        signal: this.abortController.signal
      })

      const data = await response.json()
      this.showFlightResult(data)
    } catch (error) {
      if (error.name !== "AbortError") {
        this.showStatus("Unable to validate flight", "error")
      }
    }
  }

  showFlightResult(data) {
    if (!this.hasStatusTarget) return

    const airline = data.airline || {}
    const logoHtml = airline.logo_url 
      ? `<img src="${airline.logo_url}" alt="${airline.name || ''}" class="h-5 inline-block mr-1" onerror="this.style.display='none'">`
      : ""
    const airlineName = airline.name || data.carrier || ""

    if (data.valid) {
      // Store flights for picker
      this.currentFlights = data.flights || []

      if (data.multiple_flights && data.flights && data.flights.length > 1) {
        // Check if we already have departure/arrival airports that match one of the flights
        const existingDeparture = this.hasDepartureAirportTarget ? this.departureAirportTarget.value.trim().toUpperCase() : ""
        const existingArrival = this.hasArrivalAirportTarget ? this.arrivalAirportTarget.value.trim().toUpperCase() : ""
        
        if (existingDeparture && existingArrival) {
          const matchingFlight = data.flights.find(flight => 
            flight.departure_airport?.toUpperCase() === existingDeparture && 
            flight.arrival_airport?.toUpperCase() === existingArrival
          )
          
          if (matchingFlight) {
            // Auto-select the matching flight
            this.hidePicker()
            this.applyFlightData(matchingFlight)
            
            this.statusTarget.innerHTML = `
              <div class="flex items-center gap-2 text-green-600">
                ${logoHtml}
                <span>✓ <strong>${airlineName}</strong> ${matchingFlight.departure_airport} → ${matchingFlight.arrival_airport}</span>
              </div>
            `
            this.statusTarget.className = "text-sm mt-2"
            this.statusTarget.classList.remove("hidden")
            return
          }
        }
        
        // Show flight picker if no match found
        this.showFlightPicker(data.flights, airline, logoHtml, airlineName)
      } else {
        // Single flight - apply directly
        this.hidePicker()
        this.applyFlightData(data.flights[0] || data)
        
        this.statusTarget.innerHTML = `
          <div class="flex items-center gap-2 text-green-600">
            ${logoHtml}
            <span>✓ <strong>${airlineName}</strong> ${data.departure_airport} → ${data.arrival_airport}</span>
          </div>
        `
        this.statusTarget.className = "text-sm mt-2"
        this.statusTarget.classList.remove("hidden")
      }
    } else if (airline.name) {
      this.hidePicker()
      this.statusTarget.innerHTML = `
        <div class="flex items-center gap-2 text-blue-600">
          ${logoHtml}
          <span><strong>${airlineName}</strong></span>
        </div>
      `
      this.statusTarget.className = "text-sm mt-2"
      this.statusTarget.classList.remove("hidden")
    } else if (data.error?.includes('date')) {
      this.hidePicker()
      this.statusTarget.innerHTML = `
        <div class="flex items-center gap-2 text-gray-500">
          <span>Enter flight date to look up details</span>
        </div>
      `
      this.statusTarget.className = "text-sm mt-2"
      this.statusTarget.classList.remove("hidden")
    } else {
      this.hidePicker()
      this.clearStatus()
    }
  }

  showFlightPicker(flights, airline, logoHtml, airlineName) {
    if (!this.hasFlightPickerTarget) {
      // Create picker if target doesn't exist
      this.createPickerElement()
    }

    const pickerHtml = `
      <div class="mt-2 p-3 bg-amber-50 border border-amber-200 rounded-lg">
        <div class="flex items-center gap-2 mb-2 text-amber-700">
          ${logoHtml}
          <span class="font-medium">${airlineName} - Multiple flights found</span>
        </div>
        <p class="text-sm text-amber-600 mb-3">Which flight are you on?</p>
        <div class="space-y-2">
          ${flights.map((flight, index) => `
            <button type="button" 
                    class="w-full text-left p-3 bg-white border border-gray-200 rounded-lg hover:border-blue-500 hover:bg-blue-50 transition-colors"
                    data-action="click->flight-validation#selectFlight"
                    data-flight-index="${index}">
              <div class="flex justify-between items-center">
                <div>
                  <span class="font-mono font-bold text-blue-600">${flight.departure_airport}</span>
                  <span class="text-gray-400 mx-2">→</span>
                  <span class="font-mono font-bold text-blue-600">${flight.arrival_airport}</span>
                </div>
                <div class="text-sm text-gray-500">
                  <span class="text-gray-400">${this.formatLocalDate(flight.local_departure)}</span>
                  ${this.formatLocalTime(flight.local_departure)} <span class="text-xs text-gray-400">${this.formatTimezone(flight.local_departure)}</span>
                  → ${this.formatLocalTime(flight.local_arrival)} <span class="text-xs text-gray-400">${this.formatTimezone(flight.local_arrival)}</span>
                </div>
              </div>
            </button>
          `).join('')}
        </div>
      </div>
    `

    this.flightPickerTarget.innerHTML = pickerHtml
    this.flightPickerTarget.classList.remove("hidden")

    // Show a brief status message
    this.statusTarget.innerHTML = `
      <div class="flex items-center gap-2 text-amber-600">
        <span>⚠️ Please select your flight below</span>
      </div>
    `
    this.statusTarget.className = "text-sm mt-2"
    this.statusTarget.classList.remove("hidden")
  }

  createPickerElement() {
    const picker = document.createElement('div')
    picker.setAttribute('data-flight-validation-target', 'flightPicker')
    picker.className = 'hidden'
    this.element.appendChild(picker)
  }

  selectFlight(event) {
    event.preventDefault()
    const index = parseInt(event.currentTarget.dataset.flightIndex, 10)
    const flight = this.currentFlights[index]
    
    if (flight) {
      this.applyFlightData(flight)
      this.hidePicker()
      
      this.statusTarget.innerHTML = `
        <div class="flex items-center gap-2 text-green-600">
          <span>✓ Selected: <strong>${flight.departure_airport} → ${flight.arrival_airport}</strong></span>
        </div>
      `
      this.statusTarget.className = "text-sm mt-2"
    }
  }

  applyFlightData(flight) {
    if (this.hasDepartureAirportTarget && flight.departure_airport) {
      this.departureAirportTarget.value = flight.departure_airport
    }
    if (this.hasArrivalAirportTarget && flight.arrival_airport) {
      this.arrivalAirportTarget.value = flight.arrival_airport
    }
    
    if (flight.departure_time && flight.arrival_time) {
      this.updateFlightTimes(flight.departure_time, flight.arrival_time, flight.local_departure, flight.local_arrival)
    }
  }

  hidePicker() {
    if (this.hasFlightPickerTarget) {
      this.flightPickerTarget.classList.add("hidden")
      this.flightPickerTarget.innerHTML = ""
    }
  }

  formatLocalTime(localTimeStr) {
    if (!localTimeStr) return "—"
    // Format: "2025-12-19 07:20-05:00" -> "07:20"
    const match = localTimeStr.match(/\d{4}-\d{2}-\d{2}\s+(\d{2}:\d{2})/)
    return match ? match[1] : localTimeStr.substring(11, 16) || "—"
  }

  formatTimezone(localTimeStr) {
    if (!localTimeStr) return ""
    // Format: "2025-12-19 07:20-05:00" -> "UTC-05:00" or "2025-12-19 07:20+02:00" -> "UTC+02:00"
    const match = localTimeStr.match(/([+-]\d{2}:\d{2})$/)
    return match ? `UTC${match[1]}` : ""
  }

  formatLocalDate(localTimeStr) {
    if (!localTimeStr) return ""
    // Format: "2025-12-19 07:20-05:00" -> "Dec 19"
    const match = localTimeStr.match(/(\d{4})-(\d{2})-(\d{2})/)
    if (!match) return ""
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
    const month = months[parseInt(match[2], 10) - 1]
    const day = parseInt(match[3], 10)
    return `${month} ${day}`
  }

  showStatus(message, type) {
    if (!this.hasStatusTarget) return

    const colors = {
      loading: "text-gray-500",
      success: "text-green-600",
      error: "text-red-600",
      warning: "text-yellow-600"
    }

    this.statusTarget.innerHTML = message
    this.statusTarget.className = `text-sm mt-2 ${colors[type] || "text-gray-500"}`
    this.statusTarget.classList.remove("hidden")
  }

  clearStatus() {
    if (!this.hasStatusTarget) return
    this.statusTarget.classList.add("hidden")
    this.statusTarget.innerHTML = ""
    this.hidePicker()
  }

  updateFlightTimes(departureTime, arrivalTime, localDeparture = null, localArrival = null) {
    const depTimeToSave = departureTime || null
    const arrTimeToSave = arrivalTime || null
    
    if (this.hasDepartureTimeHiddenTarget) {
      this.departureTimeHiddenTarget.value = depTimeToSave || ""
    }
    if (this.hasArrivalTimeHiddenTarget) {
      this.arrivalTimeHiddenTarget.value = arrTimeToSave || ""
    }
    
    if (this.hasTimesDisplayTarget && this.hasTimesTextTarget) {
      const depTime = localDeparture ? this.formatLocalTime(localDeparture) : this.formatTime(departureTime)
      const arrTime = localArrival ? this.formatLocalTime(localArrival) : this.formatTime(arrivalTime)
      const depTz = localDeparture ? this.formatTimezone(localDeparture) : ""
      const arrTz = localArrival ? this.formatTimezone(localArrival) : ""
      
      const depDisplay = depTz ? `${depTime} (${depTz})` : depTime
      const arrDisplay = arrTz ? `${arrTime} (${arrTz})` : arrTime
      
      this.timesTextTarget.textContent = `Departs ${depDisplay} → Arrives ${arrDisplay}`
      this.timesDisplayTarget.classList.remove("hidden")
    }
  }

  formatTime(isoString) {
    if (!isoString) return ""
    // Extract time directly from ISO string to avoid timezone conversion
    // Format: "2025-12-19T07:20:00Z" or "2025-12-19T07:20:00+00:00" -> "07:20"
    const match = isoString.match(/T(\d{2}:\d{2})/)
    return match ? match[1] : ""
  }

  updateDateFromPicker() {
    if (!this.hasDepartureDateTarget) return

    const dateValue = this.departureDateTarget.value
    if (!dateValue) return

    const depHidden = this.hasDepartureTimeHiddenTarget ? this.departureTimeHiddenTarget : null
    const arrHidden = this.hasArrivalTimeHiddenTarget ? this.arrivalTimeHiddenTarget : null
    const depCurrent = depHidden ? depHidden.value : ""

    if (depCurrent && depCurrent.includes("T")) {
      // We already have a full departure datetime (typically from OAG). Shift
      // the whole leg by the delta between the picked date and the departure's
      // own date so multi-day (overnight) arrivals keep their day offset,
      // instead of stomping both onto the picked date.
      const deltaDays = this.dayDiff(depCurrent.slice(0, 10), dateValue)
      if (deltaDays !== 0) {
        if (depHidden) depHidden.value = this.shiftIsoDate(depCurrent, deltaDays)
        if (arrHidden && arrHidden.value.includes("T")) {
          arrHidden.value = this.shiftIsoDate(arrHidden.value, deltaDays)
        }
      }
    } else {
      // Pure manual entry with no time yet — seed sensible defaults.
      if (depHidden && !depHidden.value) depHidden.value = `${dateValue}T12:00:00`
      if (arrHidden && !arrHidden.value) arrHidden.value = `${dateValue}T14:00:00`
    }
  }

  // Whole-day difference (toStr - fromStr), both "YYYY-MM-DD".
  dayDiff(fromStr, toStr) {
    const from = Date.parse(`${fromStr}T00:00:00Z`)
    const to = Date.parse(`${toStr}T00:00:00Z`)
    if (Number.isNaN(from) || Number.isNaN(to)) return 0
    return Math.round((to - from) / 86400000)
  }

  // Shift only the date portion of an ISO string by deltaDays, preserving the
  // time-of-day and any timezone suffix (e.g. "Z" / "+00:00").
  shiftIsoDate(iso, deltaDays) {
    const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})(T.*)$/)
    if (!m) return iso
    const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]))
    d.setUTCDate(d.getUTCDate() + deltaDays)
    const y = d.getUTCFullYear()
    const mo = String(d.getUTCMonth() + 1).padStart(2, "0")
    const da = String(d.getUTCDate()).padStart(2, "0")
    return `${y}-${mo}-${da}${m[4]}`
  }
}
