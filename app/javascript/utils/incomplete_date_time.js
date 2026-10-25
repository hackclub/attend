// Explains a half-typed date or time field instead of "Invalid value".
//
// Browsers only give a date/time field a value once every part of it is
// filled in, AM/PM included. Safari makes that easy to miss: parts nobody has
// typed into show grey placeholders (today's date, "PM") that look filled, so
// typing "10/30/2026 9:30" and moving on leaves the field empty and flagged as
// bad input. Script can't fill the missing part (it lives in the browser's
// closed shadow DOM), but it can say what's missing.
//
// Console forms validate themselves and ask incompleteDateTimeMessage for the
// wording. Every other form uses the browser's own validation, so one
// delegated listener swaps the bubble's text and clears it again once the
// field is complete or emptied.

const DATE_TIME_TYPES = new Set(["date", "datetime-local", "time", "month", "week"])

const explained = new WeakSet()

function uses12HourClock() {
  try {
    const { hourCycle, hour12 } = new Intl.DateTimeFormat(undefined, { hour: "numeric" }).resolvedOptions()
    return hourCycle ? hourCycle === "h11" || hourCycle === "h12" : Boolean(hour12)
  } catch {
    return false
  }
}

export function incompleteDateTimeMessage(input) {
  if (!DATE_TIME_TYPES.has(input?.type) || !input.validity?.badInput) return null

  const meridiem = uses12HourClock() ? ", including AM or PM" : ""
  if (input.type === "datetime-local") return `Fill in every part of the date and time${meridiem}.`
  if (input.type === "time") return `Fill in every part of the time${meridiem}.`
  return "Fill in every part of the date."
}

export function startIncompleteDateTimeMessages() {
  document.addEventListener("invalid", (event) => {
    const message = incompleteDateTimeMessage(event.target)
    if (!message) return
    event.target.setCustomValidity(message)
    explained.add(event.target)
  }, true)

  // A custom message keeps the field invalid until it's cleared. Finishing
  // the field fires input; clearing every part only fires key and focus
  // events, since the value was empty all along.
  const clear = (event) => {
    const input = event.target
    if (!explained.has(input) || input.validity.badInput) return
    input.setCustomValidity("")
    explained.delete(input)
  }
  for (const type of ["input", "change", "keyup", "focusout"]) {
    document.addEventListener(type, clear, true)
  }
}
