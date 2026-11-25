// Everything that differs between the two admin UIs' scanners. The scanner's
// behaviour is one set of modules; only the classes and markup it paints with
// change, and they all live here.
//
// Participant names, group labels and scan context names are user-controlled,
// so every template that becomes markup is tagged `html` and escapes its
// interpolations.
import { html, safeMarkup } from "utils/html"

// Groups are admin-created but their colour still lands in a style attribute,
// so only accept the 6-digit hex the model validates and fall back otherwise.
function safeHexColor(value) {
  return /^#?[0-9a-fA-F]{6}$/.test(String(value || "")) ? String(value) : null
}

const CLASSIC_TONES = {
  success: "bg-green-50 text-green-800 border border-green-200",
  warning: "bg-yellow-50 text-yellow-800 border border-yellow-200",
  error: "bg-red-50 text-red-700 border border-red-200"
}

const classic = {
  groupBadge(group, fallbackColor) {
    const color = safeHexColor(group.color)
    return html`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium" style="background-color: ${color || fallbackColor}; color: ${color ? "white" : "#1f2d3d"};">${group.name}</span>`
  },

  searchGroupFallback: "#e5e7eb",
  modalGroupFallback: "#ffffff",

  paintCameraStatus({ dot }, state) {
    dot.className = "w-2 h-2 rounded-full"
    if (state === "ready") dot.classList.add("bg-green-500")
    else if (state === "error") dot.classList.add("bg-red-500")
    else if (state === "scanning") dot.classList.add("bg-yellow-500", "animate-pulse")
    else dot.classList.add("bg-gray-400")
  },

  paintNfcStatus({ dot }, status) {
    dot.className = "w-2 h-2 rounded-full"
    if (status === "connected") dot.classList.add("bg-green-500")
    else if (status === "connecting") dot.classList.add("bg-yellow-500", "animate-pulse")
    else if (status === "error") dot.classList.add("bg-red-500")
    else dot.classList.add("bg-gray-400")
  },

  paintResult(element, tone, { message, detail, reload }) {
    element.className = `mt-4 rounded-lg ${CLASSIC_TONES[tone] || CLASSIC_TONES.success}`
    element.innerHTML = html`
      <div class="flex items-start gap-3 p-3 sm:p-4">
        <div class="min-w-0 flex-1">
          <p class="font-medium">${message}</p>
          ${detail ? html`<p class="text-sm mt-0.5 opacity-90">${detail}</p>` : ""}
          ${reload ? html`<button type="button" data-scan-result-reload class="mt-2 text-sm font-medium underline">Reload page</button>` : ""}
        </div>
        <button type="button" data-scan-result-dismiss aria-label="Dismiss" class="text-xl leading-none opacity-60 hover:opacity-100 min-h-[44px] min-w-[44px] -m-3 flex items-center justify-center">&times;</button>
      </div>
    `.toString()
  },

  // The classic banner has no status icon, so the message carries a ✓ / ↻.
  scanMessagePrefix(firstScan) {
    return firstScan ? "✓ " : "↻ "
  },

  searchNotice(message, tone) {
    return html`<div class="px-4 py-3 text-sm ${tone === "error" ? "text-red-700" : "text-gray-500"}">${message}</div>`
  },

  searchResult(participant) {
    return html`
      <div class="px-4 py-3 hover:bg-gray-50 cursor-pointer border-b border-gray-100 last:border-0 search-result"
           data-participant-id="${participant.id}">
        <div class="flex justify-between items-center">
          <div>
            <p class="font-medium text-sm">${participant.display_name}</p>
            <p class="text-xs text-gray-500">ID: ${participant.short_id}</p>
            ${(participant.groups && participant.groups.length) ? html`<div class="flex flex-wrap gap-1 mt-1">${participant.groups.map((group) => this.groupBadge(group, this.searchGroupFallback))}</div>` : ""}
          </div>
          <span class="text-xs px-2 py-1 rounded-full ${participant.status === "complete" ? "bg-green-100 text-green-800" : "bg-gray-100 text-gray-800"}">
            ${participant.status.replace("_", " ")}
          </span>
        </div>
      </div>
    `
  },

  paintModalHeader({ header }, firstScan) {
    header.className = firstScan
      ? "bg-gradient-to-r from-blue-600 to-blue-800 text-white px-4 sm:px-6 py-4"
      : "bg-gradient-to-r from-yellow-500 to-yellow-600 text-white px-4 sm:px-6 py-4"
  },

  modalAlert(kind) {
    switch (kind) {
      case "anaphylaxis":
        return safeMarkup('<div class="bg-red-100 border-l-4 border-red-500 text-red-700 px-4 py-3 mt-4"><strong>⚠️ Anaphylaxis Risk</strong></div>')
      case "food_allergies":
        return safeMarkup('<div class="bg-red-100 border-l-4 border-red-500 text-red-700 px-4 py-3 mt-4"><strong>⚠️ Life-Threatening Food Allergies</strong></div>')
      case "health_form_allergies":
        return safeMarkup('<div class="bg-orange-100 border-l-4 border-orange-500 text-orange-800 px-4 py-3 mt-4"><strong>⚠️ Allergies on Health Form — Check Medical Details</strong></div>')
      case "refrigeration":
        return safeMarkup('<div class="bg-blue-100 border-l-4 border-[#ec3750] text-blue-700 px-4 py-3 mt-4"><strong>❄️ Needs Medication Refrigeration</strong></div>')
    }
  },

  recentEmptySelector: ".text-center.py-8",
  recentHighlight: "bg-green-50",

  recentScan({ participant, scanContext, scannedBy }) {
    const contextInfo = scanContext?.name ? html`<span class="text-gray-400">@ ${scanContext.name}</span>` : ""
    return html`
      <div class="flex items-center justify-between border-b border-gray-100 pb-3 bg-green-50 -mx-2 px-2 rounded transition-colors">
        <div class="min-w-0 flex-1 mr-2">
          <p class="font-medium text-sm truncate">${participant.display_name}</p>
          <p class="text-xs text-gray-500">just now ${contextInfo}</p>
          <p class="text-xs text-gray-400">by ${scannedBy}</p>
        </div>
        <a href="${participant.show_url}" class="text-xs text-[#ec3750] hover:text-blue-800">View</a>
      </div>
    `
  },

  // One block of the saved-scans panel under the scan result.
  syncNotice(tone, body) {
    return html`<div class="mt-2 rounded-lg p-3 text-sm ${CLASSIC_TONES[tone] || "bg-gray-50 text-gray-700 border border-gray-200"}">${body}</div>`
  },

  syncButton: "text-sm font-medium underline min-h-[44px] sm:min-h-0",
  syncDetail: "text-xs mt-0.5 opacity-90"
}

function consoleSkin(icons) {
  const icon = (name) => safeMarkup(icons[name] || "")

  return {
    groupBadge(group) {
      const color = safeHexColor(group.color)
      if (!color) return html`<span class="cs-badge">${group.name}</span>`
      return html`<span class="cs-badge" style="background-color: ${color}; color: white;">${group.name}</span>`
    },

    // Cloudscape status indicator: the wrapper carries the colour and the
    // dot paints itself with currentColor.
    paintCameraStatus({ wrapper, dot }, state) {
      const tone = { ready: "success", error: "error", scanning: "in-progress" }[state] || "pending"
      wrapper.className = "cs-status cs-status-" + tone
      dot.className = "w-2 h-2 rounded-full bg-current"
      if (state === "scanning") dot.classList.add("animate-pulse")
    },

    paintNfcStatus({ wrapper, dot }, status) {
      const tone = { connected: "success", connecting: "in-progress", error: "error" }[status] || "stopped"
      if (wrapper) wrapper.className = "cs-status cs-status-" + tone
      dot.className = "w-2 h-2 rounded-full bg-current"
      if (status === "connecting") dot.classList.add("animate-pulse")
    },

    paintResult(element, tone, { message, detail, reload }) {
      if (!icons[tone]) tone = "success"
      element.className = `mt-4 cs-alert cs-alert-${tone}`
      element.innerHTML = html`${icon(tone)}
        <div class="min-w-0 flex-1">
          <p class="font-bold">${message}</p>
          ${detail ? html`<p class="cs-small">${detail}</p>` : ""}
          ${reload ? html`<button type="button" data-scan-result-reload class="cs-link cs-small mt-1">Reload page</button>` : ""}
        </div>
        <button type="button" data-scan-result-dismiss class="cs-btn cs-btn-inline-icon cs-btn-link -my-1 -mr-3 text-lg leading-none" title="Dismiss" aria-label="Dismiss">&times;</button>
      `.toString()
    },

    // The alert's status icon carries the tone, so unlike the classic scanner
    // there's no ✓ / ↻ prefix.
    scanMessagePrefix() {
      return ""
    },

    searchNotice(message) {
      return html`<div class="cs-menu-header">${message}</div>`
    },

    searchResult(participant) {
      return html`
        <div class="cs-menu-item min-h-11 justify-between search-result"
             data-participant-id="${participant.id}">
          <div class="min-w-0">
            <p class="font-bold truncate">${participant.display_name}</p>
            <p class="cs-small cs-muted">ID: ${participant.short_id}</p>
            ${(participant.groups && participant.groups.length) ? html`<div class="flex flex-wrap gap-1 mt-1">${participant.groups.map((group) => this.groupBadge(group))}</div>` : ""}
          </div>
          <span class="cs-badge ${participant.status === "complete" ? "cs-badge-green" : ""}">
            ${participant.status.replace("_", " ")}
          </span>
        </div>
      `
    },

    paintModalHeader({ actionText }, firstScan) {
      actionText.className = firstScan ? "cs-badge cs-badge-green" : "cs-badge cs-badge-yellow"
    },

    modalAlert(kind) {
      switch (kind) {
        case "anaphylaxis":
          return html`<div class="cs-alert cs-alert-error mt-3">${icon("warning")}<p class="cs-alert-title">Anaphylaxis Risk</p></div>`
        case "food_allergies":
          return html`<div class="cs-alert cs-alert-error mt-3">${icon("warning")}<p class="cs-alert-title">Life-Threatening Food Allergies</p></div>`
        case "health_form_allergies":
          return html`<div class="cs-alert cs-alert-warning mt-3">${icon("warning")}<p class="cs-alert-title">Allergies on Health Form — Check Medical Details</p></div>`
        case "refrigeration":
          return html`<div class="cs-alert mt-3">${icon("info")}<p class="cs-alert-title">Needs Medication Refrigeration</p></div>`
      }
    },

    recentEmptySelector: '[data-event-scans-target="empty"]',
    recentHighlight: "bg-(--cs-success-bg)",

    recentScan({ participant, scanContext, scannedBy }) {
      const contextInfo = scanContext?.name ? html`<span>@ ${scanContext.name}</span>` : ""
      return html`
        <div class="flex items-center justify-between border-b border-(--cs-border-divider-secondary) pb-3 bg-(--cs-success-bg) -mx-2 px-2 rounded transition-colors">
          <div class="min-w-0 flex-1 mr-2">
            <p class="font-bold truncate">${participant.display_name}</p>
            <p class="cs-small cs-muted"><time datetime="${new Date().toISOString()}">Now</time> ${contextInfo}</p>
            <p class="cs-small cs-muted">by ${scannedBy}</p>
          </div>
          <a href="${participant.show_url}" class="cs-link min-h-[44px] min-w-[44px] flex items-center justify-center">View</a>
        </div>
      `
    },

    syncNotice(tone, body) {
      const known = icons[tone] ? tone : "info"
      return html`<div class="cs-alert ${known === "info" ? "" : `cs-alert-${known}`} mt-2">${icon(known)}<div class="min-w-0 flex-1">${body}</div></div>`
    },

    syncButton: "cs-link cs-small min-h-11 sm:min-h-0",
    syncDetail: "cs-small"
  }
}

// `icons` maps a tone to the console's status icon markup, which the view
// renders into <template> elements because only the server has the helper.
export function createSkin(name, icons = {}) {
  return name === "console" ? consoleSkin(icons) : classic
}
