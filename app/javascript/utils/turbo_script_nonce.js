// Keeps inline <script nonce> tags running after a Turbo visit.
//
// Our CSP nonce is fresh per response (config/initializers/content_security_policy.rb),
// but a page keeps enforcing the policy it was first loaded with. Turbo re-runs
// the inline scripts of every page it renders and copies their nonce from the
// new response, which that policy has never seen, so the browser blocks them.
//
// Before each render, scripts that carry the new response's own nonce get the
// document's nonce instead. A script injected into the markup can't know the
// new response's nonce, so it stays blocked, the same as on a full page load.

function cspNonce() {
  return document.querySelector('meta[name="csp-nonce"]')?.content
}

export function startTurboScriptNonce() {
  const documentNonce = cspNonce()

  // By now Turbo has merged the new page's <head>, so the csp-nonce meta holds
  // the new response's nonce. Leave it there: Turbo stamps that meta's nonce
  // onto every script it runs, injected ones included.
  document.addEventListener("turbo:before-render", (event) => {
    const newNonce = cspNonce()

    for (const script of event.detail.newBody.querySelectorAll("script[nonce]")) {
      if (script.getAttribute("nonce") === newNonce) script.setAttribute("nonce", documentNonce)
    }
  })
}
