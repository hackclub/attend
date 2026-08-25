import { Controller } from "@hotwired/stimulus"
import { html } from "utils/html"

export default class extends Controller {
  static targets = ["input", "dropdown", "results"]
  static values = {
    searchUrl: { type: String, default: "/api/v1/travel/search_airports" }
  }

  connect() {
    this.debounceTimer = null
    this.abortController = null
    this.selectedIndex = -1
  }

  disconnect() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    if (this.abortController) this.abortController.abort()
  }

  search() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)

    const query = this.inputTarget.value.trim()
    
    if (query.length < 2) {
      this.hideDropdown()
      return
    }

    this.debounceTimer = setTimeout(() => {
      this.performSearch(query)
    }, 300)
  }

  async performSearch(query) {
    if (this.abortController) this.abortController.abort()
    this.abortController = new AbortController()

    try {
      const response = await fetch(`${this.searchUrlValue}?keyword=${encodeURIComponent(query)}`, {
        signal: this.abortController.signal,
        headers: {
          "Accept": "application/json"
        }
      })

      const data = await response.json()
      this.displayResults(data.airports || [])
    } catch (error) {
      if (error.name !== "AbortError") {
        console.error("Airport search error:", error)
      }
    }
  }

  displayResults(airports) {
    if (!airports.length) {
      this.hideDropdown()
      return
    }

    this.selectedIndex = -1
    this.resultsTarget.innerHTML = airports.map((airport, index) => html`
      <button type="button" 
              class="w-full text-left px-3 py-2 hover:bg-blue-50 focus:bg-blue-50 focus:outline-none cursor-pointer"
              data-action="click->airport-autocomplete#select"
              data-airport-autocomplete-iata-param="${airport.iata}"
              data-airport-autocomplete-name-param="${airport.name}"
              data-index="${index}">
        <span class="font-mono font-medium text-blue-600">${airport.iata}</span>
        <span class="text-gray-700">${airport.name}</span>
        ${airport.city ? html`<span class="text-gray-500 text-sm">- ${airport.city}, ${airport.country}</span>` : ""}
      </button>
    `).join("")

    this.showDropdown()
  }

  select(event) {
    event.preventDefault()
    const iata = event.params.iata
    this.inputTarget.value = iata
    this.hideDropdown()
    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  showDropdown() {
    this.dropdownTarget.classList.remove("hidden")
  }

  hideDropdown() {
    this.dropdownTarget.classList.add("hidden")
    this.selectedIndex = -1
  }

  onKeydown(event) {
    if (!this.dropdownTarget.classList.contains("hidden")) {
      const items = this.resultsTarget.querySelectorAll("button")
      
      switch (event.key) {
        case "ArrowDown":
          event.preventDefault()
          this.selectedIndex = Math.min(this.selectedIndex + 1, items.length - 1)
          this.highlightItem(items)
          break
        case "ArrowUp":
          event.preventDefault()
          this.selectedIndex = Math.max(this.selectedIndex - 1, 0)
          this.highlightItem(items)
          break
        case "Enter":
          event.preventDefault()
          if (this.selectedIndex >= 0 && items[this.selectedIndex]) {
            items[this.selectedIndex].click()
          }
          break
        case "Escape":
          this.hideDropdown()
          break
      }
    }
  }

  highlightItem(items) {
    items.forEach((item, index) => {
      if (index === this.selectedIndex) {
        item.classList.add("bg-blue-50")
        item.scrollIntoView({ block: "nearest" })
      } else {
        item.classList.remove("bg-blue-50")
      }
    })
  }

  onBlur() {
    setTimeout(() => this.hideDropdown(), 200)
  }
}
