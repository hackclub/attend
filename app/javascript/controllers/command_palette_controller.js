import { Controller } from "@hotwired/stimulus"
import { html } from "utils/html"

export default class extends Controller {
  static targets = ["modal", "input", "results", "item"]
  static values = {
    searchUrl: String
  }

  connect() {
    this.selectedIndex = -1
    this.items = []
    this.boundKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.boundKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeydown)
  }

  handleKeydown(event) {
    if ((event.metaKey || event.ctrlKey) && event.key === "k") {
      event.preventDefault()
      this.open()
    }

    if (!this.isOpen) return

    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    }

    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.selectNext()
    }

    if (event.key === "ArrowUp") {
      event.preventDefault()
      this.selectPrevious()
    }

    if (event.key === "Enter") {
      event.preventDefault()
      this.activateSelected()
    }
  }

  open() {
    this.modalTarget.classList.remove("hidden")
    this.isOpen = true
    this.inputTarget.value = ""
    this.inputTarget.focus()
    this.resetResults()
    document.body.style.overflow = "hidden"
  }

  close() {
    this.modalTarget.classList.add("hidden")
    this.isOpen = false
    this.selectedIndex = -1
    document.body.style.overflow = ""
  }

  closeOnOverlay(event) {
    if (event.target === this.modalTarget) {
      this.close()
    }
  }

  async search() {
    const query = this.inputTarget.value.trim()
    
    if (query.length === 0) {
      this.resetResults()
      return
    }

    try {
      const response = await fetch(`${this.searchUrlValue}?q=${encodeURIComponent(query)}`)
      const data = await response.json()
      this.renderResults(data)
    } catch (error) {
      console.error("Search failed:", error)
    }
  }

  resetResults() {
    this.items = this.getDefaultItems()
    this.selectedIndex = -1
    this.renderItems()
  }

  getDefaultItems() {
    const currentEventId = document.querySelector('meta[name="current-event-id"]')?.content
    
    const items = [
      { type: "navigation", label: "Events", url: "/admin", icon: "calendar", category: "Navigation" },
    ]

    if (currentEventId) {
      const currentEventSlug = document.querySelector('meta[name="current-event-slug"]')?.content
      items.push(
        { type: "navigation", label: "Event Dashboard", url: `/admin/${currentEventSlug}`, icon: "calendar", category: "Current Event" },
        { type: "navigation", label: "Participants", url: `/admin/events/${currentEventSlug}/participants`, icon: "users", category: "Current Event" },
        { type: "navigation", label: "Incidents", url: `/admin/events/${currentEventSlug}/incidents`, icon: "alert", category: "Current Event" },
        { type: "navigation", label: "QR Scanner", url: `/admin/events/${currentEventSlug}/scans`, icon: "qr", category: "Current Event" },
        { type: "navigation", label: "Travel Calendar", url: `/admin/events/${currentEventSlug}/travel`, icon: "calendar", category: "Current Event" },
        { type: "navigation", label: "Messages", url: `/admin/events/${currentEventSlug}/messages`, icon: "message", category: "Current Event" },
        { type: "navigation", label: "New Message", url: `/admin/events/${currentEventSlug}/messages/new`, icon: "message", category: "Current Event" },
        { type: "navigation", label: "Staff", url: `/admin/events/${currentEventSlug}/staff`, icon: "staff", category: "Current Event" },
        { type: "navigation", label: "Export Data", url: `/admin/events/${currentEventSlug}/exports`, icon: "download", category: "Current Event" },
        { type: "navigation", label: "Integrations", url: `/admin/${currentEventSlug}/integrations`, icon: "integration", category: "Current Event" },
        { type: "navigation", label: "New Event", url: `/admin/new`, icon: "calendar", category: "Navigation" }
      )
    }

    const isGlobalAdmin = document.querySelector('meta[name="global-admin"]')?.content === "true"
    if (isGlobalAdmin) {
      items.push(
        { type: "navigation", label: "Users", url: "/admin/users", icon: "users", category: "Administration" },
        { type: "navigation", label: "Audit Log", url: "/admin/audit_logs", icon: "log", category: "Administration" }
      )
    }

    return items
  }

  renderResults(data) {
    this.items = []
    
    if (data.participants && data.participants.length > 0) {
      data.participants.forEach(p => {
        this.items.push({
          type: "participant",
          label: p.name,
          sublabel: `${p.email} · ${p.event_name}`,
          url: p.url,
          icon: "user",
          category: "Participants"
        })
      })
    }

    if (data.events && data.events.length > 0) {
      data.events.forEach(e => {
        this.items.push({
          type: "event",
          label: e.name,
          sublabel: e.location,
          url: e.url,
          icon: "calendar",
          category: "Events"
        })
      })
    }

    if (data.users && data.users.length > 0) {
      data.users.forEach(u => {
        this.items.push({
          type: "user",
          label: u.email,
          sublabel: u.role,
          url: u.url,
          icon: "user",
          category: "Users"
        })
      })
    }

    const defaultItems = this.getDefaultItems().filter(item => 
      item.label.toLowerCase().includes(this.inputTarget.value.toLowerCase())
    )
    this.items = [...this.items, ...defaultItems]

    this.selectedIndex = this.items.length > 0 ? 0 : -1
    this.renderItems()
  }

  renderItems() {
    if (this.items.length === 0) {
      this.resultsTarget.innerHTML = `
        <div class="px-4 py-8 text-center text-gray-500">
          No results found
        </div>
      `
      return
    }

    let currentCategory = ""
    let markup = ""

    this.items.forEach((item, index) => {
      if (item.category !== currentCategory) {
        currentCategory = item.category
        markup += html`<div class="px-3 py-2 text-xs font-semibold text-gray-400 uppercase tracking-wider">${currentCategory}</div>`
      }

      const isSelected = index === this.selectedIndex
      const selectedClass = isSelected ? "bg-[#ec3750] text-white" : "text-gray-700 hover:bg-gray-100"
      const sublabelClass = isSelected ? "text-white/70" : "text-gray-400"

      markup += html`
        <a href="${item.url}" 
           class="flex items-center px-3 py-2 mx-1 rounded-lg cursor-pointer ${selectedClass}"
           data-command-palette-target="item"
           data-index="${index}"
           data-action="mouseenter->command-palette#selectByMouse click->command-palette#navigate">
          <span class="flex-shrink-0 mr-3">${this.getIcon(item.icon, isSelected)}</span>
          <span class="flex-1 truncate">
            <span class="font-medium">${item.label}</span>
            ${item.sublabel ? html`<span class="ml-2 text-sm ${sublabelClass}">${item.sublabel}</span>` : ""}
          </span>
          <span class="flex-shrink-0 ml-2">
            <kbd class="px-1.5 py-0.5 text-xs font-medium ${isSelected ? 'bg-white/20 text-white' : 'bg-gray-100 text-gray-400'} rounded">↵</kbd>
          </span>
        </a>
      `
    })

    this.resultsTarget.innerHTML = markup
  }

  getIcon(type, isSelected) {
    const color = isSelected ? "currentColor" : "#8492a6"
    const icons = {
      calendar: html`<svg class="h-5 w-5" fill="none" stroke="${color}" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"/></svg>`,
      users: html`<svg class="h-5 w-5" fill="none" stroke="${color}" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z"/></svg>`,
      user: html`<svg class="h-5 w-5" fill="none" stroke="${color}" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"/></svg>`,
      alert: html`<svg class="h-5 w-5" fill="none" stroke="${color}" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/></svg>`,
      qr: html`<svg class="h-5 w-5" fill="none" stroke="${color}" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v1m6 11h2m-6 0h-2v4m0-11v3m0 0h.01M12 12h4.01M16 20h4M4 12h4m12 0h.01M5 8h2a1 1 0 001-1V5a1 1 0 00-1-1H5a1 1 0 00-1 1v2a1 1 0 001 1zm12 0h2a1 1 0 001-1V5a1 1 0 00-1-1h-2a1 1 0 00-1 1v2a1 1 0 001 1zM5 20h2a1 1 0 001-1v-2a1 1 0 00-1-1H5a1 1 0 00-1 1v2a1 1 0 001 1z"/></svg>`,
      plane: html`<svg class="h-5 w-5" fill="none" stroke="${color}" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8"/></svg>`,
      staff: html`<svg class="h-5 w-5" fill="none" stroke="${color}" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"/></svg>`,
      download: html`<svg class="h-5 w-5" fill="none" stroke="${color}" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>`,
      log: html`<svg class="h-5 w-5" fill="none" stroke="${color}" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/></svg>`,
      message: html`<svg class="h-5 w-5" fill="none" stroke="${color}" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 10h.01M12 10h.01M16 10h.01M9 16H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-5l-5 5v-5z"/></svg>`,
      integration: html`<svg class="h-5 w-5" fill="none" stroke="${color}" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 20l4-16m4 4l4 4-4 4M6 16l-4-4 4-4"/></svg>`
    }
    return icons[type] || icons.user
  }

  selectNext() {
    if (this.items.length === 0) return
    this.selectedIndex = (this.selectedIndex + 1) % this.items.length
    this.renderItems()
    this.scrollToSelected()
  }

  selectPrevious() {
    if (this.items.length === 0) return
    this.selectedIndex = this.selectedIndex <= 0 ? this.items.length - 1 : this.selectedIndex - 1
    this.renderItems()
    this.scrollToSelected()
  }

  selectByMouse(event) {
    const index = parseInt(event.currentTarget.dataset.index, 10)
    if (!isNaN(index)) {
      this.selectedIndex = index
      this.renderItems()
    }
  }

  scrollToSelected() {
    const items = this.resultsTarget.querySelectorAll('[data-command-palette-target="item"]')
    if (items[this.selectedIndex]) {
      items[this.selectedIndex].scrollIntoView({ block: "nearest" })
    }
  }

  activateSelected() {
    if (this.selectedIndex >= 0 && this.items[this.selectedIndex]) {
      window.location.href = this.items[this.selectedIndex].url
    }
  }

  navigate(event) {
    this.close()
  }
}
