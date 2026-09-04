require "rails_helper"

RSpec.describe "Docs", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:global_admin) { User.create!(email: "ga-docs@example.com", name: "Global Admin", global_role: "global_admin") }
  let(:regular_user) { User.create!(email: "user-docs@example.com", name: "Regular User") }

  # MINTLIFY_DOCS_HOST is unset in test, so /docs is still the Scalar fallback.
  # Delete this block once the env var is set everywhere and the vendored
  # bundle goes with it.
  describe "GET /docs (Scalar fallback)" do
    it "renders for a signed-out visitor" do
      get docs_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("api-reference")
      expect(response.body).to include(openapi_path)
    end

    it "renders for a signed-in user" do
      sign_in regular_user
      get docs_path
      expect(response).to have_http_status(:ok)
    end
  end

  # The proxy is what /docs becomes once MINTLIFY_DOCS_HOST is set.
  describe "the Mintlify proxy" do
    let(:host) { "attend-docs.mintlifysite.com" }

    before { allow(Mintlify::Proxy).to receive(:host).and_return(host) }

    def stub_upstream(path, status: 200, headers: { "content-type" => "text/html" }, body: "<h1>API</h1>")
      stub_request(:get, "https://#{host}#{path}").to_return(status: status, headers: headers, body: body)
    end

    it "serves the upstream page to a signed-out visitor" do
      stub_upstream("/docs")

      get docs_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<h1>API</h1>")
      expect(response.media_type).to eq("text/html")
    end

    # Also the regression test for verify_same_origin_request: Rails rejects a
    # cross-origin GET that returns JavaScript with a 422, so without the
    # skip in DocsController every Next.js chunk 422s and the docs render
    # blank. Serve this one as application/javascript deliberately.
    it "proxies nested paths, including assets" do
      stub_upstream("/docs/_next/static/chunk.js", headers: { "content-type" => "application/javascript" }, body: "console.log(1)")

      get "/docs/_next/static/chunk.js"

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("console.log(1)")
    end

    # Even with the docs public, a signed-in staffer reading them still carries
    # a session cookie on every /docs request, and forwarding it would hand
    # that session to a third party.
    it "never forwards Attend's session cookie upstream" do
      stub_upstream("/docs")
      sign_in global_admin

      get docs_path

      expect(a_request(:get, "https://#{host}/docs").with { |req| req.headers.key?("Cookie") }).not_to have_been_made
    end

    it "sends the headers Mintlify's edge routes on, and not Host" do
      stub_upstream("/docs")

      get docs_path

      # WebMock canonicalises header names, hence X-Real-Ip.
      expect(a_request(:get, "https://#{host}/docs").with { |req|
        req.headers["Origin"] == "https://#{host}" &&
          req.headers["X-Real-Ip"].present? &&
          req.headers["X-Forwarded-Proto"].present? &&
          !req.headers.key?("Host")
      }).to have_been_made
    end

    it "rewrites an upstream redirect back onto our own origin" do
      stub_upstream("/docs/old", status: 308, headers: { "location" => "https://#{host}/docs/new" }, body: "")

      get "/docs/old"

      expect(response).to have_http_status(:permanent_redirect)
      expect(response.headers["Location"]).to eq("/docs/new")
    end

    it "passes an upstream 404 through rather than raising" do
      stub_upstream("/docs/missing", status: 404, body: "not found")

      get "/docs/missing"

      expect(response).to have_http_status(:not_found)
    end

    # The proxy takes a path and issues an outbound request with it, so the
    # host has to be pinned rather than inferred from what it was handed. The
    # router can't produce these, but the guard is what makes that safe to
    # rely on.
    describe "the upstream host is pinned" do
      it "refuses a path outside the proxied prefixes" do
        proxy = Mintlify::Proxy.new(host: host)

        expect { proxy.call(ActionDispatch::TestRequest.create, "/admin/events") }
          .to raise_error(Mintlify::Proxy::Forbidden, /refusing to proxy/)
      end

      it "refuses a protocol-relative path that would resolve to another host" do
        proxy = Mintlify::Proxy.new(host: host)

        expect { proxy.call(ActionDispatch::TestRequest.create, "//example.com/docs") }
          .to raise_error(Mintlify::Proxy::Forbidden)

        expect(a_request(:any, %r{example\.com})).not_to have_been_made
      end

      it "allows the paths the router can actually produce" do
        stub_upstream("/docs/api/events")
        stub_request(:get, "https://#{host}/.well-known/vercel/x").to_return(status: 200, body: "ok")

        get "/docs/api/events"
        expect(response).to have_http_status(:ok)

        get "/.well-known/vercel/x"
        expect(response).to have_http_status(:ok)
      end
    end

    it "answers 502 when Mintlify is unreachable" do
      stub_request(:get, "https://#{host}/docs").to_timeout

      get docs_path

      expect(response).to have_http_status(:bad_gateway)
    end

    it "serves the domain-verification path" do
      stub_request(:get, "https://#{host}/.well-known/vercel/domain-verify")
        .to_return(status: 200, headers: { "content-type" => "text/plain" }, body: "ok")

      get "/.well-known/vercel/domain-verify"

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("ok")
    end
  end

  describe "GET /openapi.json" do
    it "serves a valid OpenAPI document to anyone" do
      get openapi_path

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")

      doc = JSON.parse(response.body)
      expect(doc["openapi"]).to start_with("3.")
      expect(doc.dig("info", "title")).to eq("Attend API")
      expect(doc["paths"]).to include("/me", "/events/{event_id}/participants")
    end

    it "documents the UUID travel paths and nullable group-object entry contract" do
      get openapi_path

      doc = JSON.parse(response.body)
      canonical = doc.dig("paths", "/events/{event_id}/travel", "get")
      legacy = doc.dig("paths", "/events/{event_id}/airport_mode", "get")
      entry = doc.dig("components", "schemas", "TravelCalendarEntry", "properties")

      expect(canonical.fetch("parameters").sole).to eq("$ref" => "#/components/parameters/EventIdUuid")
      expect(legacy.fetch("parameters").sole).to eq("$ref" => "#/components/parameters/EventIdUuid")
      expect(legacy["deprecated"]).to be(true)
      expect(doc.dig("components", "parameters", "EventIdUuid", "schema")).to eq(
        "type" => "string",
        "format" => "uuid"
      )
      expect(entry.values_at("participantPreferredName", "mode", "route")).to all(include("nullable" => true))
      expect(entry.dig("groups", "items")).to eq(
        "type" => "object",
        "required" => %w[id name color],
        "properties" => {
          "id" => { "type" => "string", "format" => "uuid" },
          "name" => { "type" => "string" },
          "color" => { "type" => "string", "nullable" => true }
        }
      )
    end
  end
end
