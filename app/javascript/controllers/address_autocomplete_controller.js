import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "city", "state", "postalCode", "country"]
  static values = {
    fillComponents: { type: Boolean, default: false }
  }

  connect() {
    this.loadGoogleMapsApi()
  }

  loadGoogleMapsApi() {
    const apiKey = document.querySelector('meta[name="google-maps-api-key"]')?.content
    if (!apiKey) {
      console.warn("Google Maps API key not found")
      return
    }

    if (window.google?.maps?.places) {
      this.initAutocomplete()
      return
    }

    if (window.googleMapsLoading) {
      window.googleMapsCallbacks = window.googleMapsCallbacks || []
      window.googleMapsCallbacks.push(() => this.initAutocomplete())
      return
    }

    window.googleMapsLoading = true
    window.googleMapsCallbacks = [() => this.initAutocomplete()]

    const script = document.createElement("script")
    script.src = `https://maps.googleapis.com/maps/api/js?key=${apiKey}&libraries=places&callback=googleMapsCallback`
    script.async = true
    script.defer = true

    window.googleMapsCallback = () => {
      window.googleMapsLoading = false
      window.googleMapsCallbacks.forEach(cb => cb())
      window.googleMapsCallbacks = []
    }

    document.head.appendChild(script)
  }

  initAutocomplete() {
    if (!this.hasInputTarget) return

    const inputElement = this.inputTarget

    if (inputElement.tagName === "TEXTAREA") {
      this.initTextareaAutocomplete(inputElement)
    } else {
      this.initInputAutocomplete(inputElement)
    }
  }

  initInputAutocomplete(inputElement) {
    this.autocomplete = new google.maps.places.Autocomplete(inputElement, {
      types: ["address"],
      fields: ["address_components", "formatted_address"]
    })

    this.autocomplete.addListener("place_changed", () => this.onPlaceSelected())

    // Prevent Turbo from intercepting clicks on the Google Places dropdown
    // The pac-container is appended to body, so we need to mark it after it's created
    this.setupPacContainerForTurbo()
  }

  setupPacContainerForTurbo() {
    // Google creates the pac-container lazily, so we observe for it
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) {
          if (node.classList?.contains("pac-container")) {
            node.setAttribute("data-turbo", "false")
            // Keep observing in case Google recreates the container
          }
        }
      }
    })

    observer.observe(document.body, { childList: true })
    this.pacContainerObserver = observer

    // Also check if pac-container already exists
    document.querySelectorAll(".pac-container").forEach(el => {
      el.setAttribute("data-turbo", "false")
    })
  }

  initTextareaAutocomplete(textareaElement) {
    this.autocompleteService = new google.maps.places.AutocompleteService()
    this.placesService = new google.maps.places.PlacesService(document.createElement("div"))
    this.selectedPlace = null

    this.dropdown = document.createElement("div")
    this.dropdown.className = "absolute z-50 bg-white border border-gray-300 rounded-md shadow-lg mt-1 max-h-60 overflow-y-auto hidden"
    this.dropdown.style.width = textareaElement.offsetWidth + "px"
    textareaElement.parentNode.style.position = "relative"
    textareaElement.parentNode.appendChild(this.dropdown)

    textareaElement.addEventListener("input", () => this.onTextareaInput())
    textareaElement.addEventListener("blur", () => setTimeout(() => this.hideDropdown(), 200))
    textareaElement.addEventListener("keydown", (e) => this.onKeydown(e))
  }

  onTextareaInput() {
    const query = this.inputTarget.value.trim()
    if (query.length < 3) {
      this.hideDropdown()
      return
    }

    this.autocompleteService.getPlacePredictions(
      { input: query, types: ["address"] },
      (predictions, status) => {
        if (status === google.maps.places.PlacesServiceStatus.OK && predictions) {
          this.showPredictions(predictions)
        } else {
          this.hideDropdown()
        }
      }
    )
  }

  showPredictions(predictions) {
    this.predictions = predictions
    this.selectedIndex = -1

    this.dropdown.innerHTML = predictions.map((p, i) => `
      <div class="px-3 py-2 cursor-pointer hover:bg-blue-50 text-sm" data-index="${i}">
        ${p.description}
      </div>
    `).join("")

    this.dropdown.querySelectorAll("[data-index]").forEach(el => {
      el.addEventListener("mousedown", (e) => {
        e.preventDefault()
        this.selectPrediction(parseInt(el.dataset.index))
      })
    })

    this.dropdown.classList.remove("hidden")
  }

  hideDropdown() {
    if (this.dropdown) {
      this.dropdown.classList.add("hidden")
    }
  }

  selectPrediction(index) {
    const prediction = this.predictions[index]
    if (!prediction) return

    this.inputTarget.value = prediction.description
    this.hideDropdown()

    if (this.fillComponentsValue) {
      this.placesService.getDetails(
        { placeId: prediction.place_id, fields: ["address_components"] },
        (place, status) => {
          if (status === google.maps.places.PlacesServiceStatus.OK && place) {
            this.fillAddressComponents(place.address_components)
          }
        }
      )
    }
  }

  onKeydown(e) {
    if (!this.predictions || this.dropdown.classList.contains("hidden")) return

    if (e.key === "ArrowDown") {
      e.preventDefault()
      this.selectedIndex = Math.min(this.selectedIndex + 1, this.predictions.length - 1)
      this.highlightPrediction()
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this.selectedIndex = Math.max(this.selectedIndex - 1, 0)
      this.highlightPrediction()
    } else if (e.key === "Enter" && this.selectedIndex >= 0) {
      e.preventDefault()
      this.selectPrediction(this.selectedIndex)
    } else if (e.key === "Escape") {
      this.hideDropdown()
    }
  }

  highlightPrediction() {
    this.dropdown.querySelectorAll("[data-index]").forEach((el, i) => {
      el.classList.toggle("bg-blue-50", i === this.selectedIndex)
    })
  }

  onPlaceSelected() {
    const place = this.autocomplete.getPlace()
    if (!place.address_components) return

    if (this.fillComponentsValue) {
      this.fillAddressComponents(place.address_components)
    } else {
      this.inputTarget.value = place.formatted_address
    }
  }

  fillAddressComponents(components) {
    let streetNumber = ""
    let route = ""
    let city = ""
    let state = ""
    let postalCode = ""
    let country = ""

    for (const component of components) {
      const type = component.types[0]
      switch (type) {
        case "street_number":
          streetNumber = component.long_name
          break
        case "route":
          route = component.long_name
          break
        case "locality":
        case "postal_town":
          city = component.long_name
          break
        case "administrative_area_level_1":
          state = component.long_name
          break
        case "postal_code":
          postalCode = component.long_name
          break
        case "country":
          country = component.long_name
          break
      }
    }

    this.inputTarget.value = [streetNumber, route].filter(Boolean).join(" ")

    if (this.hasCityTarget) this.cityTarget.value = city
    if (this.hasStateTarget) this.stateTarget.value = state
    if (this.hasPostalCodeTarget) this.postalCodeTarget.value = postalCode
    if (this.hasCountryTarget) {
      if (this.countryTarget.tagName === "SELECT") {
        const option = Array.from(this.countryTarget.options).find(
          opt => opt.value.toLowerCase() === country.toLowerCase()
        )
        if (option) this.countryTarget.value = option.value
      } else {
        this.countryTarget.value = country
      }
    }
  }

  disconnect() {
    if (this.autocomplete) {
      google.maps.event.clearInstanceListeners(this.autocomplete)
    }
    if (this.pacContainerObserver) {
      this.pacContainerObserver.disconnect()
    }
  }
}
