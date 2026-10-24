import assert from "node:assert/strict"
import test from "node:test"

const { startTurboScriptNonce } = await import(new URL("../../app/javascript/utils/turbo_script_nonce.js", import.meta.url))

function script(nonce) {
  const attributes = { nonce }
  return {
    getAttribute(name) { return attributes[name] },
    setAttribute(name, value) { attributes[name] = value }
  }
}

test("gives the new page's own scripts the document's nonce, and only those", () => {
  let metaNonce = "document"
  const listeners = {}
  globalThis.document = {
    querySelector() { return { content: metaNonce } },
    addEventListener(type, listener) { listeners[type] = listener }
  }
  startTurboScriptNonce()

  // Turbo merges the new page's head, csp-nonce meta included, before it renders.
  metaNonce = "new-response"
  const ours = script("new-response")
  const injected = script("guessed")
  listeners["turbo:before-render"]({ detail: { newBody: { querySelectorAll() { return [ ours, injected ] } } } })

  assert.equal(ours.getAttribute("nonce"), "document")
  assert.equal(injected.getAttribute("nonce"), "guessed")
})
