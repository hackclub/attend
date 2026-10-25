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
//
// A back/forward visit renders a cached copy of the page instead, where the
// browser has hidden every nonce attribute (""). The copy still holds the nonce
// each script ran with, though, so scripts that ran under the document's nonce
// get it back. Previews of a cached page are left alone: the real render that
// follows runs their scripts.

function cspNonce() {
  return document.querySelector('meta[name="csp-nonce"]')?.content
}

function isPreview() {
  return document.documentElement.hasAttribute("data-turbo-preview")
}

export function startTurboScriptNonce() {
  const documentNonce = cspNonce()

  // By now Turbo has merged the new page's <head>, so the csp-nonce meta holds
  // the new response's nonce. Leave it there: Turbo stamps that meta's nonce
  // onto every script it runs, injected ones included.
  document.addEventListener("turbo:before-render", (event) => {
    const newNonce = cspNonce()
    const restoring = !isPreview()

    for (const script of event.detail.newBody.querySelectorAll("script[nonce]")) {
      const nonce = script.getAttribute("nonce")
      const fromCache = nonce === "" && restoring && script.nonce === documentNonce

      if (nonce === newNonce || fromCache) script.setAttribute("nonce", documentNonce)
    }
  })
}
