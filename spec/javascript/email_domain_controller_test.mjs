import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const source = await readFile(new URL("../../app/javascript/controllers/email_domain_controller.js", import.meta.url), "utf8")
const runnable = source.replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
const { default: EmailDomainController } = await import(`data:text/javascript;base64,${Buffer.from(runnable).toString("base64")}`)

function buildController(value) {
  const input = {
    value,
    customValidity: "",
    classList: {
      classes: new Set(),
      add(...names) { names.forEach((name) => this.classes.add(name)) },
      remove(...names) { names.forEach((name) => this.classes.delete(name)) }
    },
    setCustomValidity(message) { this.customValidity = message }
  }
  const message = {
    textContent: "",
    hidden: true,
    classList: {
      add(name) { if (name === "hidden") message.hidden = true },
      remove(name) { if (name === "hidden") message.hidden = false }
    }
  }
  const controller = new EmailDomainController()
  controller.inputTarget = input
  controller.messageTarget = message
  controller.hasMessageTarget = true
  controller.domainsValue = [ "hackclub.com", "events.hackclub.com" ]

  return { controller, input, message }
}

test("rejects an address outside the allowed domains", () => {
  const { controller, input, message } = buildController("hi@gmail.com")

  controller.validate()

  assert.equal(input.customValidity, "Must be a @hackclub.com or @events.hackclub.com address.")
  assert.equal(message.textContent, "Must be a @hackclub.com or @events.hackclub.com address.")
  assert.equal(message.hidden, false)
  assert.ok(input.classList.classes.has("border-red-500"))
})

test("accepts the allowed domains regardless of case or padding", () => {
  for (const value of [ "team@hackclub.com", "  Sunbeam@Events.Hackclub.com  " ]) {
    const { controller, input, message } = buildController(value)

    controller.validate()

    assert.equal(input.customValidity, "")
    assert.equal(message.hidden, true)
    assert.equal(input.classList.classes.size, 0)
  }
})

test("stays quiet until a domain has been typed", () => {
  for (const value of [ "", "team", "team@" ]) {
    const { controller, input, message } = buildController(value)

    controller.validate()

    assert.equal(input.customValidity, "")
    assert.equal(message.hidden, true)
  }
})

test("does not accept a lookalike subdomain", () => {
  const { controller, input } = buildController("hi@evil-hackclub.com")

  controller.validate()

  assert.equal(input.customValidity, "Must be a @hackclub.com or @events.hackclub.com address.")
})
