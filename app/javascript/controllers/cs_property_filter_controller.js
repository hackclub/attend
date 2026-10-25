import { Controller } from "@hotwired/stimulus"
import { dropBlankFields } from "utils/drop_blank_fields"
import { html } from "utils/html"

// Cloudscape property filter for the admin console
// (https://cloudscape.design/components/property-filter/), built as a
// progressive enhancement over plain filter controls.
//
// The server renders the controls it already understands — a text field
// (`text` target) and one select per property (`property` targets, labelled
// by data-cs-property-filter-label or aria-label) — inside the `fallback`
// target. Without JavaScript those are the filter UI. On connect this
// controller hides them and shows the `enhanced` target instead: one
// combobox input that suggests properties, then that property's values, and
// writes the choice back into the matching control.
//
// Two modes:
// - submit (default): choosing a value submits the surrounding GET form, so
//   the URL stays the source of truth. Tokens are rendered by the server
//   (ConsoleHelper#cs_filter_tokens) as links to the page without that
//   filter.
// - live (data-cs-property-filter-live-value="true"): the controls are read
//   by another controller that filters on the client. Choosing a value sets
//   the control and fires the event that controller listens for; tokens,
//   the "N matches" count and "Clear filters" are rendered here.
//
// Each property takes one value and properties are always ANDed, matching
// the server, so the operation between tokens is a fixed "and" and choosing
// a second value for a property replaces the first.

const CLOSE_ICON = html`<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8"/></svg>`
const REFOCUS_KEY = "cs-property-filter-refocus"

export default class extends Controller {
  static targets = ["input", "listbox", "enhanced", "fallback", "property", "text", "tokens", "count"]

  static values = {
    live: Boolean,
    textLabel: { type: String, default: "Text" },
    itemSelector: String
  }

  connect() {
    this.activeIndex = -1
    this.options = []

    if (this.hasFallbackTarget) this.fallbackTarget.hidden = true
    if (this.hasEnhancedTarget) this.enhancedTarget.hidden = false

    if (this.liveValue) {
      // Let a sibling controller read its own state (the travel calendar
      // reads the query string into the selects on connect) before drawing.
      this.liveTimer = setTimeout(() => this.renderLive(), 0)
    } else {
      this.form = this.element.closest("form") || this.element.querySelector("form")
      this.dropBlankFields = (event) => dropBlankFields(event.formData)
      this.form?.addEventListener("formdata", this.dropBlankFields)
      this.restoreFocus()
    }
  }

  disconnect() {
    clearTimeout(this.liveTimer)
    this.form?.removeEventListener("formdata", this.dropBlankFields)
  }

  // --- Suggestions --------------------------------------------------------

  get properties() {
    return this.propertyTargets.map((control) => ({
      control,
      label: control.dataset.csPropertyFilterLabel || control.getAttribute("aria-label") || control.name,
      options: Array.from(control.options)
        .filter((option) => option.value !== "")
        .map((option) => ({ value: option.value, label: option.textContent.trim() }))
    }))
  }

  // The property the input is scoped to, when it starts "<Property> =".
  scopedProperty(raw) {
    const lower = raw.toLowerCase()
    return this.properties.find((property) => lower.startsWith(`${property.label.toLowerCase()} =`))
  }

  buildItems() {
    const raw = this.inputTarget.value
    const scoped = this.scopedProperty(raw)

    if (scoped) {
      const query = raw.slice(scoped.label.length).replace(/^\s*=\s*/, "").trim().toLowerCase()
      const values = scoped.options
        .filter((option) => !query || option.label.toLowerCase().includes(query))
        .map((option) => this.valueItem(scoped, option, option.label))
      return values.length ? [ { group: `${scoped.label} values` }, ...values ] : []
    }

    const query = raw.trim()
    const lower = query.toLowerCase()
    const items = []

    if (query && this.hasTextTarget) {
      items.push({ kind: "text", text: query, label: `Use: "${query}"`, meta: `${this.textLabelValue} contains` })
    }

    const properties = this.properties.filter((property) => !lower || property.label.toLowerCase().includes(lower))
    if (properties.length) {
      items.push({ group: "Properties" })
      properties.forEach((property) => items.push({ kind: "property", property, label: property.label }))
    }

    if (lower) {
      const values = this.properties.flatMap((property) =>
        property.options
          .filter((option) => option.label.toLowerCase().includes(lower))
          .map((option) => this.valueItem(property, option, `${property.label} = ${option.label}`))
      )
      if (values.length) items.push({ group: "Values" }, ...values)
    }

    return items
  }

  valueItem(property, option, label) {
    return { kind: "value", property, option, label, current: property.control.value === option.value }
  }

  render() {
    const items = this.buildItems()
    this.options = items.filter((item) => !item.group)
    if (this.activeIndex >= this.options.length) this.activeIndex = this.options.length - 1

    const id = this.listboxTarget.id
    let index = 0
    const markup = items.map((item) => {
      if (item.group) return html`<li role="presentation" class="cs-menu-group-label">${item.group}</li>`

      const optionIndex = index++
      return html`<li role="option" id="${id}-option-${optionIndex}"
        aria-selected="${optionIndex === this.activeIndex ? "true" : "false"}"
        ${item.current ? html`aria-current="true"` : ""}
        data-action="click->cs-property-filter#choose"
        data-cs-property-filter-index-param="${optionIndex}"><span>${item.label}</span>${item.meta ? html`<span class="cs-property-filter-option-meta">${item.meta}</span>` : ""}</li>`
    })

    this.listboxTarget.innerHTML = (markup.length
      ? html`${markup}`
      : html`<li role="presentation" class="cs-property-filter-empty-option">No suggestions</li>`).toString()
    this.syncActiveDescendant()
  }

  // --- Opening and closing ------------------------------------------------

  open() {
    if (this.suppressOpen) {
      this.suppressOpen = false
      return
    }
    this.render()
    this.listboxTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", "true")
  }

  close() {
    this.listboxTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.activeIndex = -1
    this.inputTarget.removeAttribute("aria-activedescendant")
  }

  get isOpen() {
    return !this.listboxTarget.hidden
  }

  refresh() {
    this.activeIndex = -1
    this.open()
  }

  // Clicking an option must not blur the input, or the list closes first.
  keepFocus(event) {
    event.preventDefault()
  }

  // --- Keyboard -----------------------------------------------------------

  keydown(event) {
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        if (!this.isOpen) this.open()
        this.move(1)
        break
      case "ArrowUp":
        event.preventDefault()
        if (!this.isOpen) this.open()
        this.move(-1)
        break
      case "Home":
      case "End":
        if (this.isOpen && this.activeIndex >= 0 && this.options.length) {
          event.preventDefault()
          this.activeIndex = event.key === "Home" ? 0 : this.options.length - 1
          this.syncActiveDescendant()
        }
        break
      case "Enter":
        // Never let Enter submit the form directly: a half-typed
        // "Status = co" isn't a search term.
        event.preventDefault()
        this.enter()
        break
      case "Escape":
        if (this.isOpen) {
          event.preventDefault()
          this.close()
        } else if (this.inputTarget.value) {
          event.preventDefault()
          this.inputTarget.value = ""
        }
        break
      case "Backspace":
        if (this.inputTarget.value === "") {
          event.preventDefault()
          this.removeLast()
        }
        break
      case "Tab":
        this.close()
        break
    }
  }

  enter() {
    if (this.isOpen && this.activeIndex >= 0) {
      this.select(this.options[this.activeIndex])
      return
    }

    const raw = this.inputTarget.value.trim()
    if (!raw) return

    const scoped = this.scopedProperty(raw)
    if (scoped) {
      // "Status = complete" typed out in full still applies.
      const query = raw.slice(scoped.label.length).replace(/^\s*=\s*/, "").trim().toLowerCase()
      const exact = scoped.options.find((option) => option.label.toLowerCase() === query)
      if (exact) this.apply(scoped.control, exact.value)
      return
    }

    if (this.hasTextTarget) this.apply(this.textTarget, raw)
  }

  move(delta) {
    if (!this.options.length) return

    if (this.activeIndex < 0) {
      this.activeIndex = delta > 0 ? 0 : this.options.length - 1
    } else {
      this.activeIndex = (this.activeIndex + delta + this.options.length) % this.options.length
    }
    this.syncActiveDescendant()
  }

  syncActiveDescendant() {
    const options = this.listboxTarget.querySelectorAll("[role='option']")
    options.forEach((option, index) => option.setAttribute("aria-selected", index === this.activeIndex ? "true" : "false"))

    const active = options[this.activeIndex]
    if (active) {
      this.inputTarget.setAttribute("aria-activedescendant", active.id)
      active.scrollIntoView({ block: "nearest" })
    } else {
      this.inputTarget.removeAttribute("aria-activedescendant")
    }
  }

  // --- Choosing -----------------------------------------------------------

  choose({ params: { index } }) {
    this.select(this.options[index])
  }

  select(item) {
    if (!item) return

    if (item.kind === "property") {
      this.inputTarget.value = `${item.property.label} = `
      this.activeIndex = -1
      this.inputTarget.focus()
      this.open()
    } else if (item.kind === "value") {
      this.apply(item.property.control, item.option.value)
    } else if (item.kind === "text") {
      this.apply(this.textTarget, item.text)
    }
  }

  apply(control, value) {
    control.value = value
    this.inputTarget.value = ""
    this.close()

    if (this.liveValue) {
      this.notify(control)
      this.renderLive()
    } else {
      this.submit()
    }
  }

  removeLast() {
    if (this.liveValue) {
      const filters = this.activeFilters()
      const last = filters[filters.length - 1]
      if (last) this.apply(last.control, "")
      return
    }

    if (!this.hasTokensTarget) return
    const links = this.tokensTarget.querySelectorAll("[data-cs-property-filter-remove]")
    const last = links[links.length - 1]
    if (last) {
      this.rememberFocus()
      last.click()
    }
  }

  // Live-mode token dismiss button.
  remove({ params: { index } }) {
    const filter = this.activeFilters()[index]
    if (filter) this.apply(filter.control, "")
    this.inputTarget.focus()
  }

  // Live-mode "Clear filters".
  clear() {
    this.activeFilters().forEach((filter) => {
      filter.control.value = ""
      this.notify(filter.control)
    })
    this.inputTarget.value = ""
    this.renderLive()
    this.suppressOpen = true
    this.inputTarget.focus()
    this.suppressOpen = false
  }

  notify(control) {
    control.dispatchEvent(new Event(control.tagName === "SELECT" ? "change" : "input", { bubbles: true }))
  }

  submit() {
    if (!this.form) return

    this.rememberFocus()
    this.form.requestSubmit()
  }

  // Keyboard users keep their place across the page visit a submit causes.
  rememberFocus() {
    try {
      sessionStorage.setItem(REFOCUS_KEY, this.inputTarget.id || this.listboxTarget.id)
    } catch {
      // Storage can be unavailable; losing focus is the only cost.
    }
  }

  restoreFocus() {
    let key = null
    try {
      key = sessionStorage.getItem(REFOCUS_KEY)
      if (key) sessionStorage.removeItem(REFOCUS_KEY)
    } catch {
      return
    }

    if (key && key === (this.inputTarget.id || this.listboxTarget.id)) {
      this.suppressOpen = true
      this.inputTarget.focus()
      this.suppressOpen = false
    }
  }

  // --- Live tokens --------------------------------------------------------

  activeFilters() {
    const filters = []

    if (this.hasTextTarget && this.textTarget.value.trim()) {
      const value = `“${this.textTarget.value.trim()}”`
      filters.push({ control: this.textTarget, label: this.textLabelValue, operator: "contains", value })
    }

    this.properties.forEach((property) => {
      const option = property.options.find((candidate) => candidate.value === property.control.value)
      if (option) filters.push({ control: property.control, label: property.label, operator: "=", value: option.label })
    })

    return filters.map((filter) => ({ ...filter, text: `${filter.label} ${filter.operator} ${filter.value}` }))
  }

  renderLive() {
    const filters = this.activeFilters()

    if (this.hasTokensTarget) {
      this.tokensTarget.hidden = filters.length === 0
      this.tokensTarget.innerHTML = (filters.length
        ? html`<ul class="cs-token-group" aria-label="Applied filters">${filters.map((filter, index) => html`<li class="cs-filter-token-item">${index ? html`<span class="cs-filter-operation">and</span>` : ""}<span class="cs-token"><span class="cs-filter-token-text" title="${filter.text}">${filter.label} <span class="cs-filter-token-operator">${filter.operator}</span> <strong>${filter.value}</strong></span><button type="button" aria-label="Remove filter ${filter.text}" data-action="cs-property-filter#remove" data-cs-property-filter-index-param="${index}">${CLOSE_ICON}</button></span></li>`)}</ul><button type="button" class="cs-btn cs-btn-link cs-filter-clear" data-action="cs-property-filter#clear">Clear filters</button>`
        : html``).toString()
    }

    if (this.hasCountTarget) {
      if (filters.length && this.itemSelectorValue) {
        const visible = Array.from(this.element.querySelectorAll(this.itemSelectorValue)).filter((item) => !item.hidden).length
        this.countTarget.textContent = `${visible} ${visible === 1 ? "match" : "matches"}`
        this.countTarget.hidden = false
      } else {
        this.countTarget.textContent = ""
        this.countTarget.hidden = true
      }
    }
  }
}
