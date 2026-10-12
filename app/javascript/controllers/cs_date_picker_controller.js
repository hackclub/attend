import { Controller } from "@hotwired/stimulus"
import { html, safeMarkup } from "utils/html"

// Cloudscape's date picker for the admin console: every native date and
// datetime-local field inside this controller's element gets a calendar
// button that opens Cloudscape's calendar (cloudscape.design/components/calendar).
//
// The native input stays the source of truth, so typing, form submission,
// min/max validation and other controllers listening for input/change all
// keep working. For datetime-local fields the calendar sets the date and
// keeps whatever time is already there.
//
// Fields are picked up as they appear (Turbo frames, nested-form
// templates), and a field opts out with data-cs-date-picker="off".
//
// Bound fields are tracked in a WeakSet rather than a data attribute: a
// Turbo cache snapshot keeps the wrapper markup but not its listeners, so a
// restored page has to be re-bound, not skipped.

const FIELD_SELECTOR = 'input[type="date"], input[type="datetime-local"]'

const CALENDAR_ICON = safeMarkup('<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="1.5" y="2.5" width="13" height="12" rx="1.5"/><path d="M1.5 6.5h13M5 1v3m6-3v3"/></svg>')
const PREV_ICON = safeMarkup('<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10 3L5 8l5 5"/></svg>')
const NEXT_ICON = safeMarkup('<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 3l5 5-5 5"/></svg>')

const pad = (n) => String(n).padStart(2, "0")
const isoDate = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
const sameDay = (a, b) => a && b && isoDate(a) === isoDate(b)

// Parses "YYYY-MM-DD" (or the date half of "YYYY-MM-DDTHH:MM") as a local
// date; `new Date("2026-10-12")` would be UTC midnight and slip a day west.
const parseIso = (value) => {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(value || "")
  return match ? new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3])) : null
}

const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n)
const addMonths = (d, n) => {
  const target = new Date(d.getFullYear(), d.getMonth() + n, 1)
  const lastDay = new Date(target.getFullYear(), target.getMonth() + 1, 0).getDate()
  return new Date(target.getFullYear(), target.getMonth(), Math.min(d.getDate(), lastDay))
}

let instance = 0
const bound = new WeakSet()

export default class extends Controller {
  connect() {
    this.locale = document.documentElement.lang || "en-US"
    this.enhanceAll()
    // Only rescan when a date field might have arrived; the calendar's own
    // re-renders happen inside .cs-calendar and are ignored.
    this.observer = new MutationObserver((mutations) => {
      const relevant = mutations.some((mutation) => [...mutation.addedNodes].some((node) =>
        node.nodeType === Node.ELEMENT_NODE &&
        !node.closest(".cs-calendar") &&
        (node.matches(FIELD_SELECTOR) || node.querySelector(FIELD_SELECTOR))))
      // Busy pages (the rooming board, Turbo Stream swaps) add nodes in
      // bursts; collapse each burst into one scan per frame.
      if (relevant && !this.scanQueued) {
        this.scanQueued = true
        requestAnimationFrame(() => {
          this.scanQueued = false
          this.enhanceAll()
        })
      }
    })
    this.observer.observe(this.element, { childList: true, subtree: true })

    this.beforeCacheHandler = () => this.close({ restoreFocus: false })
    document.addEventListener("turbo:before-cache", this.beforeCacheHandler)

    this.outsideHandler = (event) => {
      if (this.open && !this.open.wrapper.contains(event.target)) this.close({ restoreFocus: false })
    }
    document.addEventListener("mousedown", this.outsideHandler)
  }

  disconnect() {
    this.observer?.disconnect()
    document.removeEventListener("mousedown", this.outsideHandler)
    document.removeEventListener("turbo:before-cache", this.beforeCacheHandler)
    this.close({ restoreFocus: false })
  }

  enhanceAll() {
    this.element.querySelectorAll(FIELD_SELECTOR).forEach((input) => this.enhance(input))
  }

  enhance(input) {
    if (input.dataset.csDatePicker === "off" || bound.has(input)) return
    bound.add(input)

    // A wrapper left over from a Turbo cache snapshot has a dead button;
    // unwrap it and build a fresh one.
    const stale = input.parentElement
    if (stale?.classList.contains("cs-datepicker")) {
      stale.replaceWith(input)
    }

    const wrapper = document.createElement("span")
    wrapper.className = "cs-datepicker"
    input.parentNode.insertBefore(wrapper, input)
    wrapper.appendChild(input)

    const trigger = document.createElement("button")
    trigger.type = "button"
    trigger.className = "cs-datepicker-trigger"
    trigger.innerHTML = CALENDAR_ICON.toString()
    trigger.setAttribute("aria-haspopup", "dialog")
    trigger.setAttribute("aria-expanded", "false")
    trigger.setAttribute("aria-label", this.triggerLabel(input))
    // Disabled/readonly is read at click time rather than copied once:
    // other controllers enable and disable fields after setup.
    trigger.addEventListener("click", () => {
      if (this.open?.input === input) this.close()
      else if (!input.disabled && !input.readOnly) this.show(input, wrapper, trigger)
    })
    wrapper.appendChild(trigger)

    // Tabbing out of the field or the calendar closes it, so it never sits
    // over the fields that follow.
    wrapper.addEventListener("focusout", (event) => {
      if (this.open?.wrapper === wrapper && event.relatedTarget && !wrapper.contains(event.relatedTarget)) {
        this.close({ restoreFocus: false })
      }
    })

    input.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown" && event.altKey && !input.disabled && !input.readOnly) {
        event.preventDefault()
        this.show(input, wrapper, trigger)
      }
    })
  }

  triggerLabel(input) {
    const label = input.id && this.element.querySelector(`label[for="${CSS.escape(input.id)}"]`)
    // Leave out the console's "- optional" marker.
    const copy = label?.cloneNode(true)
    copy?.querySelectorAll(".cs-field-optional").forEach((node) => node.remove())
    const name = copy?.textContent?.trim()
    return name ? `Choose date for ${name}` : "Choose date"
  }

  show(input, wrapper, trigger) {
    this.close({ restoreFocus: false })

    const selected = parseIso(input.value)
    const focused = selected || this.clamp(new Date(), input)
    const popover = document.createElement("div")
    popover.className = "cs-calendar"
    popover.id = `cs-calendar-${++instance}`
    popover.setAttribute("role", "dialog")
    popover.setAttribute("aria-label", trigger.getAttribute("aria-label"))
    popover.addEventListener("keydown", (event) => this.onKeydown(event))
    wrapper.appendChild(popover)

    trigger.setAttribute("aria-expanded", "true")
    trigger.setAttribute("aria-controls", popover.id)
    this.open = { input, wrapper, trigger, popover, selected, focused, month: new Date(focused.getFullYear(), focused.getMonth(), 1) }
    this.render({ focusGrid: true })
    this.place()
  }

  close({ restoreFocus = true } = {}) {
    if (!this.open) return
    const { popover, trigger } = this.open
    popover.remove()
    trigger.setAttribute("aria-expanded", "false")
    trigger.removeAttribute("aria-controls")
    if (restoreFocus) trigger.focus()
    this.open = null
  }

  // Opens upward when there isn't room below the field.
  place() {
    const { popover, wrapper } = this.open
    const below = window.innerHeight - wrapper.getBoundingClientRect().bottom
    popover.classList.toggle("cs-calendar-up", below < popover.offsetHeight + 12 && wrapper.getBoundingClientRect().top > popover.offsetHeight + 12)
  }

  bounds(input) {
    return { min: parseIso(input.min), max: parseIso(input.max) }
  }

  isDisabled(date, input) {
    const { min, max } = this.bounds(input)
    return (min && date < min) || (max && date > max)
  }

  clamp(date, input) {
    const { min, max } = this.bounds(input)
    if (min && date < min) return min
    if (max && date > max) return max
    return date
  }

  render({ focusGrid = false, focusNav = null } = {}) {
    const { popover, input, selected, focused, month } = this.open
    const today = new Date()
    const monthLabel = month.toLocaleDateString(this.locale, { month: "long", year: "numeric" })
    const weekStart = this.weekStart()

    const weekdayFormatter = new Intl.DateTimeFormat(this.locale, { weekday: "short" })
    const weekdayLong = new Intl.DateTimeFormat(this.locale, { weekday: "long" })
    const anySunday = new Date(2023, 0, 1)
    const headers = Array.from({ length: 7 }, (_, i) => {
      const day = addDays(anySunday, (i + weekStart) % 7)
      return html`<th scope="col" class="cs-calendar-weekday"><abbr title="${weekdayLong.format(day)}">${weekdayFormatter.format(day)}</abbr></th>`
    })

    const offset = (month.getDay() - weekStart + 7) % 7
    let day = addDays(month, -offset)
    const rows = []
    do {
      const cells = []
      for (let i = 0; i < 7; i++) {
        const isToday = sameDay(day, today)
        const isSelected = sameDay(day, selected)
        const classes = ["cs-calendar-day"]
        if (day.getMonth() !== month.getMonth()) classes.push("cs-calendar-day-outside")
        if (isToday) classes.push("cs-calendar-day-today")
        if (isSelected) classes.push("cs-calendar-day-selected")
        const label = day.toLocaleDateString(this.locale, { weekday: "long", month: "long", day: "numeric", year: "numeric" })
        cells.push(html`<td role="gridcell" aria-selected="${isSelected}">
          <button type="button" class="${classes.join(" ")}" data-date="${isoDate(day)}" tabindex="${sameDay(day, focused) ? 0 : -1}"
            aria-label="${isToday ? `${label}, today` : label}" aria-current="${isToday ? "date" : "false"}" aria-disabled="${this.isDisabled(day, input) ? "true" : "false"}">${day.getDate()}</button>
        </td>`)
        day = addDays(day, 1)
      }
      rows.push(html`<tr>${cells}</tr>`)
    } while (day.getMonth() === month.getMonth())

    popover.innerHTML = html`
      <div class="cs-calendar-header">
        <button type="button" class="cs-calendar-nav" data-step="-1" aria-label="Previous month">${PREV_ICON}</button>
        <h2 class="cs-calendar-title" aria-live="polite">${monthLabel}</h2>
        <button type="button" class="cs-calendar-nav" data-step="1" aria-label="Next month">${NEXT_ICON}</button>
      </div>
      <table class="cs-calendar-grid" role="grid" aria-label="${monthLabel}">
        <thead><tr>${headers}</tr></thead>
        <tbody>${rows}</tbody>
      </table>`.toString()

    popover.querySelectorAll(".cs-calendar-nav").forEach((button) => {
      button.addEventListener("click", () => {
        const step = Number(button.dataset.step)
        this.moveFocus(addMonths(this.open.focused, step), { focusGrid: false, focusNav: step })
      })
    })
    popover.querySelectorAll(".cs-calendar-day").forEach((button) => {
      button.addEventListener("click", () => this.select(parseIso(button.dataset.date)))
    })

    // Re-rendering replaces every button, so focus has to be put back or it
    // falls to <body> and the calendar stops hearing Escape and arrow keys.
    if (focusGrid) popover.querySelector('.cs-calendar-day[tabindex="0"]')?.focus()
    else if (focusNav !== null) popover.querySelector(`.cs-calendar-nav[data-step="${focusNav}"]`)?.focus()
  }

  // Sunday-first for en-US, Monday-first where the locale says so.
  weekStart() {
    try {
      const info = new Intl.Locale(this.locale).getWeekInfo?.() || new Intl.Locale(this.locale).weekInfo
      if (info?.firstDay) return info.firstDay % 7
    } catch (e) {
      // Older engines lack weekInfo; fall through to Sunday.
    }
    return 0
  }

  moveFocus(date, { focusGrid = true, focusNav = null } = {}) {
    this.open.focused = date
    this.open.month = new Date(date.getFullYear(), date.getMonth(), 1)
    this.render({ focusGrid, focusNav })
  }

  select(date) {
    const { input } = this.open
    if (!date || this.isDisabled(date, input)) return

    let value
    if (input.type === "datetime-local") {
      const time = /T(\d{2}:\d{2})/.exec(input.value)?.[1] || "00:00"
      value = `${isoDate(date)}T${time}`
    } else {
      value = isoDate(date)
    }
    // The day grid only knows dates. On a datetime field, picking the min or
    // max day with a time outside the bound would slip past it, so pull the
    // value back inside. ISO strings of the same shape compare correctly.
    const width = value.length
    if (input.min && value < input.min.slice(0, width)) value = input.min.slice(0, width)
    if (input.max && value > input.max.slice(0, width)) value = input.max.slice(0, width)
    input.value = value
    input.dispatchEvent(new Event("input", { bubbles: true }))
    input.dispatchEvent(new Event("change", { bubbles: true }))
    this.close({ restoreFocus: false })
    input.focus()
  }

  onKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      this.close()
      return
    }
    if (!event.target.classList.contains("cs-calendar-day")) return

    const focused = this.open.focused
    const weekStart = this.weekStart()
    const moves = {
      ArrowLeft: () => addDays(focused, -1),
      ArrowRight: () => addDays(focused, 1),
      ArrowUp: () => addDays(focused, -7),
      ArrowDown: () => addDays(focused, 7),
      PageUp: () => addMonths(focused, event.shiftKey ? -12 : -1),
      PageDown: () => addMonths(focused, event.shiftKey ? 12 : 1),
      Home: () => addDays(focused, -((focused.getDay() - weekStart + 7) % 7)),
      End: () => addDays(focused, 6 - ((focused.getDay() - weekStart + 7) % 7))
    }

    if (moves[event.key]) {
      event.preventDefault()
      this.moveFocus(moves[event.key]())
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      this.select(parseIso(event.target.dataset.date))
    }
  }
}
