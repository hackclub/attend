import assert from "node:assert/strict"
import test from "node:test"

const { startTurboScriptNonce } = await import(new URL("../../app/javascript/utils/turbo_script_nonce.js", import.meta.url))

// A cached copy keeps the nonce a script ran with (script.nonce) while the
// browser hides the attribute, so the two can differ.
function script(nonce, ranWith = nonce) {
  const attributes = { nonce }
  return {
    nonce: ranWith,
    getAttribute(name) { return attributes[name] },
    setAttribute(name, value) { attributes[name] = value }
  }
}

function startOn({ preview = false } = {}) {
  const page = { metaNonce: "document", preview }
  const listeners = {}
  globalThis.document = {
    documentElement: { hasAttribute(name) { return name === "data-turbo-preview" && page.preview } },
    querySelector() { return { content: page.metaNonce } },
    addEventListener(type, listener) { listeners[type] = listener }
  }
  startTurboScriptNonce()

  page.render = (scripts) =>
    listeners["turbo:before-render"]({ detail: { newBody: { querySelectorAll() { return scripts } } } })
  return page
}

test("gives the new page's own scripts the document's nonce, and only those", () => {
  const page = startOn()

  // Turbo merges the new page's head, csp-nonce meta included, before it renders.
  page.metaNonce = "new-response"
  const ours = script("new-response")
  const injected = script("guessed")
  page.render([ ours, injected ])

  assert.equal(ours.getAttribute("nonce"), "document")
  assert.equal(injected.getAttribute("nonce"), "guessed")
})

test("gives a restored page's scripts back the nonce they ran with, and only those", () => {
  const page = startOn()

  const ours = script("", "document")
  const injected = script("", "guessed")
  page.render([ ours, injected ])

  assert.equal(ours.getAttribute("nonce"), "document")
  assert.equal(injected.getAttribute("nonce"), "")
})

test("leaves a cached preview's scripts blocked, since the real render runs them", () => {
  const page = startOn({ preview: true })

  const ours = script("", "document")
  page.render([ ours ])

  assert.equal(ours.getAttribute("nonce"), "")
})
