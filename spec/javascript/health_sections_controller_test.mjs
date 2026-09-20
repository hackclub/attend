import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const source = await readFile(new URL("../../app/javascript/controllers/health_sections_controller.js", import.meta.url), "utf8")
const runnable = source.replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
const { default: HealthSectionsController } = await import(`data:text/javascript;base64,${Buffer.from(runnable).toString("base64")}`)

test("clears exact placeholders on blur and dispatches autosave change", () => {
  const events = []
  const explanation = { textContent: "" }
  const section = {
    querySelector(selector) {
      if (selector.includes("explanation")) return explanation
      return null
    }
  }
  const input = {
    value: "  N/A ",
    closest() { return section },
    dispatchEvent(event) { events.push(event.type) }
  }
  const controller = new HealthSectionsController()

  controller.normalizePlaceholder({ target: input })

  assert.equal(input.value, "")
  assert.equal(explanation.textContent, '“n/a” was treated as no additional details.')
  assert.deepEqual(events, [ "change" ])
})

test("keeps ambiguous and meaningful values untouched", () => {
  for (const value of [ "No", "none", "n/a.", "n/a for medication, but i need access" ]) {
    const input = { value, dispatchEvent() {}, closest() { return null } }
    const controller = new HealthSectionsController()

    controller.normalizePlaceholder({ target: input })

    assert.equal(input.value, value)
  }
})

test("keeps current details visible when selecting nothing to add", () => {
  const details = { classList: { remove() {}, toggle() {} } }
  const clearControl = { classList: { remove() {}, add() {} } }
  const summary = { textContent: "" }
  const radio = { checked: true, value: "nothing_to_add" }
  const section = {
    dataset: { hasDetails: "false" },
    querySelector(selector) {
      if (selector.includes("section_response")) return radio
      if (selector.includes('data-health-sections-target="details"')) return details
      if (selector.includes("clearControl")) return clearControl
      if (selector.includes("summary")) return summary
      return null
    },
    querySelectorAll(selector) {
      if (selector.startsWith("textarea")) return [ { value: "  asthma  " } ]
      if (selector.includes('input[type="checkbox"]')) return []
      return []
    }
  }
  const controller = new HealthSectionsController()

  controller.updateSection(section)

  assert.equal(summary.textContent, "Clear saved details to confirm nothing to add")
})
