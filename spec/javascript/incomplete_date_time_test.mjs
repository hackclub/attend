import assert from "node:assert/strict"
import test from "node:test"

const { incompleteDateTimeMessage, startIncompleteDateTimeMessages } =
  await import(new URL("../../app/javascript/utils/incomplete_date_time.js", import.meta.url))

// A field the way Safari leaves it after "10/30/2026 9:30" with no AM/PM:
// an empty value flagged as bad input.
function field(type, { badInput = true } = {}) {
  return {
    type,
    customMessage: "",
    validity: { badInput },
    setCustomValidity(message) { this.customMessage = message }
  }
}

function withHourCycle(hourCycle, run) {
  const original = Intl.DateTimeFormat
  Intl.DateTimeFormat = function () {
    return { resolvedOptions: () => ({ hourCycle }) }
  }
  try {
    return run()
  } finally {
    Intl.DateTimeFormat = original
  }
}

function start() {
  const listeners = {}
  globalThis.document = {
    addEventListener(type, listener, capture) {
      assert.equal(capture, true, `${type} listens in the capture phase`)
      listeners[type] = listener
    }
  }
  startIncompleteDateTimeMessages()
  return (type, target) => listeners[type]({ target })
}

test("asks for AM or PM on a 12-hour clock", () => {
  withHourCycle("h12", () => {
    assert.equal(incompleteDateTimeMessage(field("datetime-local")),
      "Fill in every part of the date and time, including AM or PM.")
    assert.equal(incompleteDateTimeMessage(field("time")), "Fill in every part of the time, including AM or PM.")
  })
})

test("leaves AM and PM out on a 24-hour clock", () => {
  withHourCycle("h23", () => {
    assert.equal(incompleteDateTimeMessage(field("datetime-local")), "Fill in every part of the date and time.")
    assert.equal(incompleteDateTimeMessage(field("date")), "Fill in every part of the date.")
  })
})

test("says nothing about complete date fields or other inputs", () => {
  assert.equal(incompleteDateTimeMessage(field("datetime-local", { badInput: false })), null)
  assert.equal(incompleteDateTimeMessage(field("number")), null)
  assert.equal(incompleteDateTimeMessage(null), null)
})

test("replaces the browser's message on a half-typed field", () => {
  const fire = start()
  const input = field("datetime-local")
  withHourCycle("h12", () => fire("invalid", input))
  assert.equal(input.customMessage, "Fill in every part of the date and time, including AM or PM.")
})

test("keeps the message while the field is still half-typed", () => {
  const fire = start()
  const input = field("datetime-local")
  fire("invalid", input)
  fire("keyup", input)
  fire("focusout", input)
  assert.notEqual(input.customMessage, "")
})

test("clears the message once the field is finished or emptied", () => {
  for (const type of ["input", "change", "keyup", "focusout"]) {
    const fire = start()
    const input = field("datetime-local")
    fire("invalid", input)
    input.validity.badInput = false
    fire(type, input)
    assert.equal(input.customMessage, "", `cleared on ${type}`)
  }
})

test("leaves messages it didn't set alone", () => {
  const fire = start()
  const input = field("date", { badInput: false })
  input.setCustomValidity("Pick a date after the event starts.")
  fire("invalid", input)
  fire("input", input)
  assert.equal(input.customMessage, "Pick a date after the event starts.")
})
