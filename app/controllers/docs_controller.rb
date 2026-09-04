# The public API reference.
#
# `show` reverse-proxies /docs onto the Mintlify-hosted docs (Mintlify::Proxy).
# While MINTLIFY_DOCS_HOST is unset it falls back to the vendored Scalar
# reference instead, so this ships before the Mintlify site is live and the
# cutover is one env var in Orchard rather than a deploy.
#
# `openapi` serves docs/openapi.yml — the same file Mintlify builds the
# reference from, so there is one spec and nothing to keep in sync. It sits at
# /openapi.json rather than under /docs because the proxy claims that prefix.
#
# None of this is gated any more. The reference was admin-only under Scalar,
# but the spec now lives in a public repo and Mintlify renders it publicly, so
# a gate on our copy would protect nothing and would only stop people pointing
# tooling at it. Every endpoint it documents is token-authenticated in its own
# right; the spec describes that surface, it does not open it.
class DocsController < ApplicationController
  # Nothing under /docs renders a Rails form, and Mintlify's bundle makes XHRs
  # we never issued a token for.
  skip_forgery_protection

  layout false

  def show
    return render :index unless Mintlify::Proxy.configured?

    proxy
  end

  # Mintlify proves it controls the proxied domain by fetching
  # /.well-known/vercel/... on the *apex* rather than under the base path,
  # which is why this route sits outside /docs.
  def vercel_verification
    return head :not_found unless Mintlify::Proxy.configured?

    proxy
  end

  def openapi
    render json: openapi_document
  end

  private

  def proxy
    result = Mintlify::Proxy.new.call(request, request.path)

    # The proxied HTML is Mintlify's, carrying its own inline scripts and its
    # own CSP. Ours would block their bundle outright — script-src has no
    # unsafe-inline and we have no way to nonce someone else's markup — so let
    # their policy through untouched instead of layering ours on top. Setting
    # this to nil stops the middleware emitting our header for this response
    # only; the Scalar fallback above still gets the full app policy.
    request.content_security_policy = nil

    result.headers.each { |name, value| response.set_header(canonical_header(name), value) }
    response.set_header("Cache-Control", "no-store")

    return head result.status if result.body.empty?

    send_data result.body,
      status: result.status,
      type: result.headers["content-type"].presence || "application/octet-stream",
      disposition: "inline"
  rescue Mintlify::Proxy::Unavailable => e
    Rails.logger.error("[Docs] Mintlify proxy failed for #{request.path}: #{e.message}")
    render plain: "The API reference is temporarily unavailable.", status: :bad_gateway
  end

  # Faraday hands headers back lowercased; Rack wants them in the usual
  # Hyphen-Capitalised form.
  def canonical_header(name)
    name.split("-").map(&:capitalize).join("-")
  end

  def openapi_document
    @openapi_document ||= YAML.load_file(Rails.root.join("docs", "openapi.yml"))
  end
end
