import { Controller } from "@hotwired/stimulus"
import { html } from "utils/html"

export default class extends Controller {
  static targets = ["content", "chevron"]
  static values = {
    journey: Object,
    participantName: String,
    eventSlug: String,
    expanded: { type: Boolean, default: false }
  }

  toggle(event) {
    if (event.target.closest('a, button, form, input')) return
    event.preventDefault()
    this.expandedValue ? this.collapse() : this.expand()
  }

  expand() {
    this.expandedValue = true
    const journey = this.journeyValue
    this.contentTarget.innerHTML = this.buildExpandedContent(journey).toString()
    this.contentTarget.classList.remove("hidden")
    if (this.hasChevronTarget) {
      this.chevronTarget.querySelector('svg').classList.add('rotate-180')
    }
  }

  collapse() {
    this.expandedValue = false
    this.contentTarget.classList.add("hidden")
    this.contentTarget.innerHTML = ""
    if (this.hasChevronTarget) {
      this.chevronTarget.querySelector('svg').classList.remove('rotate-180')
    }
  }

  buildExpandedContent(journey) {
    const legs = journey.legs || []
    const isUM = journey.is_unaccompanied_minor

    return html`
      <div class="border-t border-gray-200 bg-gray-50 p-4">
        ${isUM ? html`
          <div class="mb-4 p-3 bg-red-100 border border-red-300 rounded-lg flex items-center gap-2 text-red-800 font-bold">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/></svg>
            Unaccompanied minor — requires special handling
          </div>
        ` : ''}

        <div class="space-y-2">
          ${legs.map((leg, idx) => this.buildLegCard(leg, idx, legs, journey))}
        </div>

        ${this.buildSummary(journey, legs)}

        <div class="mt-4 pt-3 border-t border-gray-200 flex items-center justify-between gap-2">
          <a href="/admin/events/${this.eventSlugValue}/participants/${journey.participant_event_id}/travel"
             class="text-sm text-blue-600 hover:text-blue-800 font-medium">
            View full travel details →
          </a>
          ${this.buildPickupButton(journey)}
        </div>
      </div>
    `
  }

  buildLegCard(leg, index, allLegs, journey) {
    const depTime = this.formatTime(leg.etd_iso || leg.departure_time, leg.departure_tz)
    const arrTime = this.formatTime(leg.eta_iso  || leg.arrival_time, leg.arrival_tz)
    const tzNote = (tz, iata) => tz
      ? html`<div class="text-[10px] text-gray-400">local ${iata}</div>`
      : html`<div class="text-[10px] text-amber-600">tz unknown</div>`
    const depTzNote = tzNote(leg.departure_tz, leg.departure_airport)
    const arrTzNote = tzNote(leg.arrival_tz, leg.arrival_airport)
    const delayBadge = leg.is_delayed
      ? html`<span class="px-1.5 py-0.5 rounded text-[11px] font-bold bg-red-100 text-red-700">+${leg.delay_minutes}m</span>`
      : ''
    const scheduledStrike = leg.is_delayed && leg.scheduled_arrival_iso
      ? html`<div class="text-[11px] text-gray-400 line-through">was ${this.formatTime(leg.scheduled_arrival_iso, leg.arrival_tz)}</div>`
      : ''
    const statusBadge = leg.status_label
      ? html`<span class="px-2 py-0.5 rounded-full text-xs font-medium ${this.statusClass(leg.status_color)}">${leg.status_label}</span>`
      : ''

    let connectionHtml = ''
    if (index < allLegs.length - 1) {
      const next = allLegs[index + 1]
      const mins = this.diffMinutes(leg.eta_iso || leg.arrival_time, next.etd_iso || next.departure_time)
      if (mins !== null) {
        const h = Math.floor(mins / 60), m = mins % 60
        const txt = h > 0 ? `${h}h ${m}m` : `${m}m`
        const tight = mins < 60
        connectionHtml = html`
          <div class="flex items-center justify-center py-1 text-xs ${tight ? 'text-orange-600 font-medium' : 'text-gray-500'}">
            ${txt} connection at ${leg.arrival_airport}
            ${tight ? html`<span class="ml-2 bg-orange-100 text-orange-700 px-1.5 rounded text-[11px]">Tight</span>` : ''}
          </div>`
      }
    }

    return html`
      <div class="bg-white rounded-lg border border-gray-200 p-3">
        <div class="flex items-center justify-between gap-3 flex-wrap">
          <div class="flex items-center gap-2">
            <span class="font-mono font-bold text-blue-600">${leg.flight_code}</span>
            ${statusBadge}
            ${delayBadge}
          </div>
          <div class="flex items-center gap-3 text-sm">
            <div class="text-center">
              <div class="font-bold">${leg.departure_airport}</div>
              <div class="text-gray-600">${depTime}</div>
              ${depTzNote}
              ${leg.departure_terminal ? html`<div class="text-[11px] text-gray-400">T${leg.departure_terminal}${leg.departure_gate ? ' · ' + leg.departure_gate : ''}</div>` : ''}
            </div>
            <span class="text-gray-300">→</span>
            <div class="text-center">
              <div class="font-bold">${leg.arrival_airport}</div>
              <div class="text-gray-600">${arrTime}</div>
              ${arrTzNote}
              ${scheduledStrike}
              ${leg.arrival_terminal ? html`<div class="text-[11px] text-gray-400">T${leg.arrival_terminal}${leg.arrival_gate ? ' · ' + leg.arrival_gate : ''}</div>` : ''}
            </div>
          </div>
          ${leg.aircraft_type ? html`<div class="text-[11px] text-gray-400">${leg.aircraft_type}${leg.registration ? ' · ' + leg.registration : ''}</div>` : ''}
        </div>
        <div class="mt-2 flex items-center justify-end gap-3">
          <span data-controller="flight-leg-refresh"
                data-flight-leg-refresh-url-value="/admin/events/${this.eventSlugValue}/participants/${journey.participant_event_id}/refresh_flight_leg?leg_id=${leg.id}">
            <button type="button"
                    data-action="click->flight-leg-refresh#refresh"
                    class="text-[11px] text-gray-500 hover:text-blue-700 underline disabled:opacity-50">
              Refresh status
            </button>
          </span>
          ${leg.report_url ? html`
            <a href="${leg.report_url}" target="_blank" rel="noopener" class="text-[11px] text-gray-400 hover:text-red-600 underline">
              Report bad data
            </a>
          ` : ''}
        </div>
      </div>
      ${connectionHtml}
    `
  }

  buildSummary(journey, legs) {
    if (legs.length <= 1) return ''
    const totalMin = this.diffMinutes(legs[0].etd_iso || legs[0].departure_time, legs[legs.length - 1].eta_iso || legs[legs.length - 1].arrival_time)
    if (totalMin == null) return ''
    const h = Math.floor(totalMin / 60), m = totalMin % 60
    const txt = h > 0 ? `${h}h ${m}m` : `${m}m`
    return html`
      <div class="mt-3 p-2 bg-white rounded-lg border border-gray-200 flex items-center justify-between text-sm">
        <span class="text-gray-600"><span class="font-medium">${legs[0].departure_airport} → ${legs[legs.length-1].arrival_airport}</span> · ${legs.length - 1} stop${legs.length - 1 > 1 ? 's' : ''}</span>
        <span class="font-bold">Total: ${txt}</span>
      </div>
    `
  }

  buildPickupButton(journey) {
    if (journey.direction !== "inbound") return ''
    if (journey.status !== "landed") return ''

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || ''
    const url = `/admin/events/${this.eventSlugValue}/airport_mode/dismiss_pickup?travel_id=${journey.id}`
    return html`
      <form action="${url}" method="post" class="inline">
        <input type="hidden" name="authenticity_token" value="${csrfToken}">
        <button type="submit" class="px-3 py-1.5 text-sm bg-green-600 text-white rounded-lg hover:bg-green-700 font-medium">
          Mark picked up
        </button>
      </form>
    `
  }

  formatTime(iso, tz) {
    if (!iso) return '—'
    try {
      const opts = { hour: '2-digit', minute: '2-digit', hour12: false }
      if (tz) opts.timeZone = tz
      return new Date(iso).toLocaleTimeString([], opts)
    } catch { return '—' }
  }

  diffMinutes(a, b) {
    if (!a || !b) return null
    try { return Math.round((new Date(b) - new Date(a)) / 60000) } catch { return null }
  }

  statusClass(color) {
    return ({
      green:  'bg-green-100 text-green-800',
      blue:   'bg-blue-100 text-blue-800',
      red:    'bg-red-100 text-red-800',
      amber:  'bg-amber-100 text-amber-800',
      orange: 'bg-orange-100 text-orange-800',
      gray:   'bg-gray-100 text-gray-700'
    })[color] || 'bg-gray-100 text-gray-700'
  }
}
