import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "inboundMode", "outboundMode",
    "inboundPlane", "inboundTrain", "inboundBus", "inboundCar", "inboundOther",
    "outboundPlane", "outboundTrain", "outboundBus", "outboundCar", "outboundOther",
    "inboundLegs", "outboundLegs", "legTemplate",
    "umCheckbox", "umSection"
  ]

  connect() {
    this.updateFields()
    this.toggleUmSection()
    this.setupFormSubmitHandler()
  }

  toggleUmSection() {
    if (!this.hasUmSectionTarget) return

    const anyChecked = this.umCheckboxTargets.some(checkbox => checkbox.checked)
    this.umSectionTarget.classList.toggle("hidden", !anyChecked)
  }

  setupFormSubmitHandler() {
    const form = this.element.closest("form")
    if (form) {
      form.addEventListener("submit", this.handleFormSubmit.bind(this))
    }
  }

  handleFormSubmit() {
    // Remove required attributes from empty additional legs to prevent Safari validation errors
    // Only the first leg (index 0) should be required
    const allLegsContainers = [
      this.hasInboundLegsTarget ? this.inboundLegsTarget : null,
      this.hasOutboundLegsTarget ? this.outboundLegsTarget : null
    ].filter(Boolean)

    allLegsContainers.forEach(container => {
      const legs = container.querySelectorAll("[data-travel-form-target='legTemplate']")
      legs.forEach((leg, index) => {
        if (index > 0) {
          // For additional legs, check if they're empty
          const flightCode = leg.querySelector(".leg-flight-code")?.value?.trim()
          const departureAirport = leg.querySelector(".leg-departure-airport")?.value?.trim()
          const arrivalAirport = leg.querySelector(".leg-arrival-airport")?.value?.trim()

          // If the leg is essentially empty, remove required attributes
          if (!flightCode && !departureAirport && !arrivalAirport) {
            leg.querySelectorAll("[required]").forEach(el => {
              el.removeAttribute("required")
            })
          }
        }
      })
    })
  }

  updateFields() {
    this.updateDirection("inbound")
    this.updateDirection("outbound")
  }

  updateDirection(direction) {
    const modeTarget = direction === "inbound" ? this.inboundModeTarget : this.outboundModeTarget
    const mode = modeTarget.value

    const modes = ["plane", "train", "bus", "car", "other"]
    modes.forEach(m => {
      const targetName = `${direction}${m.charAt(0).toUpperCase() + m.slice(1)}Target`
      if (this[`has${targetName.charAt(0).toUpperCase() + targetName.slice(1)}`]) {
        const target = this[targetName]
        if (m === mode) {
          target.classList.remove("hidden")
          // Enable required fields in visible section
          target.querySelectorAll("[data-required]").forEach(el => {
            el.setAttribute("required", "")
          })
          // Re-enable all inputs in visible section
          target.querySelectorAll("input, select, textarea").forEach(el => {
            el.removeAttribute("disabled")
          })
        } else {
          target.classList.add("hidden")
          // Disable required fields in hidden sections to allow form submission
          target.querySelectorAll("[required]").forEach(el => {
            el.setAttribute("data-required", "true")
            el.removeAttribute("required")
          })
          // Disable all inputs in hidden sections to prevent their values from being submitted
          target.querySelectorAll("input, select, textarea").forEach(el => {
            el.setAttribute("disabled", "true")
          })
        }
      }
    })
  }

  addLeg(event) {
    event.preventDefault()
    const direction = event.currentTarget.dataset.direction
    const legsContainer = direction === "inbound" ? this.inboundLegsTarget : this.outboundLegsTarget
    const template = document.getElementById("leg-template")
    
    const legCount = legsContainer.querySelectorAll("[data-travel-form-target='legTemplate']").length
    const newLeg = template.content.cloneNode(true)
    
    // Update the leg number display
    newLeg.querySelector(".leg-number").textContent = `Leg ${legCount + 1}`
    
    // Update field names with correct indices
    const prefix = `travel_${direction}[travel_legs_attributes][${legCount}]`
    newLeg.querySelector(".leg-position").name = `${prefix}[position]`
    newLeg.querySelector(".leg-position").value = legCount
    newLeg.querySelector(".leg-flight-code").name = `${prefix}[flight_code]`
    newLeg.querySelector(".leg-confirmation-code").name = `${prefix}[confirmation_code]`
    newLeg.querySelector(".leg-departure-airport").name = `${prefix}[departure_airport]`
    newLeg.querySelector(".leg-arrival-airport").name = `${prefix}[arrival_airport]`
    newLeg.querySelector(".leg-departure-time").name = `${prefix}[departure_time]`
    newLeg.querySelector(".leg-arrival-time").name = `${prefix}[arrival_time]`
    newLeg.querySelector(".leg-departure-tz").name = `${prefix}[departure_time_zone]`
    newLeg.querySelector(".leg-arrival-tz").name = `${prefix}[arrival_time_zone]`

    // Seed a sensible date on the new leg's time pickers from a sibling leg, so
    // travellers only adjust the time rather than re-entering the whole date.
    const siblingTime = legsContainer.querySelector(".leg-departure-time")?.value
    if (siblingTime) {
      const siblingDate = siblingTime.slice(0, 10)
      newLeg.querySelector(".leg-departure-time").value = `${siblingDate}T00:00`
      newLeg.querySelector(".leg-arrival-time").value = `${siblingDate}T00:00`
    }

    legsContainer.appendChild(newLeg)
    this.updateLegNumbers(legsContainer)
  }

  removeLeg(event) {
    event.preventDefault()
    const legElement = event.currentTarget.closest("[data-travel-form-target='legTemplate']")
    const legsContainer = legElement.parentElement
    
    // If leg has an ID (persisted), mark it for destruction instead of removing from DOM
    const idField = legElement.querySelector("input[name*='[id]']")
    if (idField && idField.value) {
      // Create hidden fields to preserve the id and mark for destruction
      const idHidden = document.createElement("input")
      idHidden.type = "hidden"
      idHidden.name = idField.name
      idHidden.value = idField.value
      
      const destroyField = document.createElement("input")
      destroyField.type = "hidden"
      destroyField.name = idField.name.replace("[id]", "[_destroy]")
      destroyField.value = "1"
      
      legsContainer.appendChild(idHidden)
      legsContainer.appendChild(destroyField)
    }
    
    legElement.remove()
    this.updateLegNumbers(legsContainer)
  }

  updateLegNumbers(container) {
    const legs = container.querySelectorAll("[data-travel-form-target='legTemplate']")
    legs.forEach((leg, index) => {
      const numberEl = leg.querySelector(".leg-number")
      if (numberEl) {
        numberEl.textContent = `Leg ${index + 1}`
      }
    })
  }
}
