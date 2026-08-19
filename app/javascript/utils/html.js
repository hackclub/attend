// Escaping helpers for the handful of places where we build markup in JS and
// hand it to innerHTML / insertAdjacentHTML.
//
// Most of what those templates interpolate is participant-controlled text — a
// name, a preferred name, a flight code, a group label — so it has to be
// treated as text, never as markup. Prefer the `html` tag over hand-rolled
// escaping: it escapes every interpolation by default, so a template stays
// safe when someone later adds another `${...}` to it.

const HTML_ESCAPES = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
  "`": "&#96;",
  "=": "&#61;"
}

// Escapes `=` and backtick as well as the usual five, so a value is also safe
// dropped into an unquoted attribute.
export function escapeHtml(value) {
  if (value === null || value === undefined) return ""
  return String(value).replace(/[&<>"'`=]/g, (char) => HTML_ESCAPES[char])
}

// Wrapper marking a string as already-escaped markup, so `html` passes it
// through untouched. Only ever wrap markup we built ourselves.
class SafeMarkup {
  constructor(value) {
    this.value = value
  }

  toString() {
    return this.value
  }
}

export function safeMarkup(value) {
  return new SafeMarkup(String(value))
}

function interpolate(value) {
  if (value instanceof SafeMarkup) return value.value
  if (Array.isArray(value)) return value.map(interpolate).join("")
  // Skip the falsey values conditionals produce (`cond ? html`...` : ""`, and
  // `cond && html`...``) rather than printing "null"/"undefined"/"false".
  if (value === null || value === undefined || value === false) return ""
  return escapeHtml(value)
}

// Tagged template that escapes every interpolated value. Nested `html`
// templates (and anything wrapped in `safeMarkup`) are inlined as markup, so
// templates compose.
export function html(strings, ...values) {
  let out = strings[0]
  values.forEach((value, index) => {
    out += interpolate(value) + strings[index + 1]
  })
  return safeMarkup(out)
}
