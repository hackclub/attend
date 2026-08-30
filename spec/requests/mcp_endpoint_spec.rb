require "rails_helper"

# The only test that drives the MCP endpoint through the real mcp
# StreamableHTTPTransport rather than calling a toolbox directly. toolchest and
# the mcp gem are versioned separately and the SDK keeps changing the signatures
# toolchest overrides, so this is what catches a broken bump — see
# config/initializers/toolchest_mcp_compat.rb.
RSpec.describe "MCP endpoint", type: :request do
  let(:user) { create(:user) }

  let(:oauth_application) do
    Toolchest::OauthApplication.create!(
      name: "Spec client",
      redirect_uri: "https://client.example.com/callback"
    )
  end

  let(:access_token) do
    Toolchest::OauthAccessToken.create_for(
      application: oauth_application,
      resource_owner_id: user.id,
      scopes: "events:read"
    )
  end

  def rpc(method, params = {}, id: 1, token: access_token.raw_token, headers: {})
    post "/mcp",
      params: { jsonrpc: "2.0", id: id, method: method, params: params }.to_json,
      headers: {
        "Authorization" => ("Bearer #{token}" if token),
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream"
      }.compact.merge(headers)

    response.body.presence && JSON.parse(response.body)
  end

  def initialize_session
    rpc("initialize", {
      protocolVersion: MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "spec", version: "1" }
    })
  end

  def modern_params(params = {})
    params.merge(
      _meta: {
        MCP::RequestEnvelope::PROTOCOL_VERSION_META_KEY => MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION,
        MCP::RequestEnvelope::CLIENT_CAPABILITIES_META_KEY => {},
        MCP::RequestEnvelope::CLIENT_INFO_META_KEY => { name: "spec", version: "1" }
      }
    )
  end

  def modern_headers(method, name: nil)
    headers = {
      "MCP-Protocol-Version" => MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION,
      "Mcp-Method" => method
    }
    headers["Mcp-Name"] = name if name
    headers
  end

  it "requires a bearer token" do
    rpc("initialize", {}, token: nil)

    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["WWW-Authenticate"]).to include("oauth-protected-resource")
  end

  it "negotiates initialize and identifies itself as Attend" do
    body = initialize_session

    expect(response).to have_http_status(:ok)
    expect(body.dig("result", "serverInfo", "name")).to eq("Attend")
    expect(body.dig("result", "protocolVersion"))
      .to eq(MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION)
  end

  it "advertises and serves the modern stateless lifecycle" do
    discovery = rpc("server/discover")

    expect(discovery.dig("result", "supportedVersions"))
      .to include(MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION)
    expect(discovery.dig("result", "capabilities")).to eq("tools" => {})
    expect(discovery.dig("result", "resultType")).to eq("complete")

    tools = rpc("tools/list", modern_params, id: 2, headers: modern_headers("tools/list"))

    expect(tools.dig("result", "tools")).to be_an(Array), tools.inspect
    expect(tools.dig("result", "resultType")).to eq("complete")
    expect(tools.dig("result", "ttlMs")).to eq(0)
    expect(tools.dig("result", "cacheScope")).to eq("private")

    listen = rpc(
      "subscriptions/listen",
      modern_params,
      id: 3,
      headers: modern_headers("subscriptions/listen")
    )

    expect(response).to have_http_status(:not_found)
    expect(listen.dig("error", "code")).to eq(-32601)
  end

  it "runs statelessly, so it issues no session and needs none" do
    initialize_session

    expect(response.headers["Mcp-Session-Id"]).to be_nil

    # A follow-up request with no session ID still works — the point of stateless
    # mode, since the next request can land on a different Puma worker or pod.
    body = rpc("tools/list", {}, id: 2)

    expect(response).to have_http_status(:ok)
    expect(body["result"]).to be_present
  end

  it "lists the tools the token's scopes allow" do
    initialize_session
    body = rpc("tools/list", {}, id: 2)

    names = body.dig("result", "tools").map { |tool| tool["name"] }

    expect(names).to include("events_index")
    # events:read only — nothing that writes, and nothing safeguarding-related.
    expect(names).not_to include("events_create", "incidents_index")
  end

  it "calls a tool as the token's user" do
    event = create(:event)
    user.event_role_assignments.create!(event: event, role: "event_admin")

    body = rpc(
      "tools/call",
      modern_params(name: "events_index", arguments: {}),
      id: 2,
      headers: modern_headers("tools/call", name: "events_index")
    )

    expect(response).to have_http_status(:ok)
    expect(body["error"]).to be_nil
    expect(body.dig("result", "resultType")).to eq("complete")

    text = body.dig("result", "content").map { |part| part["text"] }.join
    expect(JSON.parse(text).fetch("events").map { |e| e["slug"] }).to eq([ event.slug ])
  end

  it "reports a tool error without leaking a 500" do
    initialize_session
    body = rpc("tools/call", { name: "events_show", arguments: { "event_id" => "nope" } }, id: 2)

    expect(response).to have_http_status(:ok)
    expect(body.dig("result", "isError")).to be(true)
  end

  describe "Host header validation" do
    # Rails' own host authorization allows everything in the test environment
    # (config.hosts is empty), so stub it to prove the transport defers to it.
    before { allow(Rails.application.config).to receive(:hosts).and_return([ "attend.hackclub.com" ]) }

    it "accepts a host Rails allows, even though it isn't loopback" do
      initialize_session_with_host("attend.hackclub.com")

      expect(response).to have_http_status(:ok)
    end

    it "rejects a host Rails would reject" do
      initialize_session_with_host("attacker.example.com")

      expect(response).to have_http_status(:forbidden)
    end

    def initialize_session_with_host(host)
      rpc("initialize", { protocolVersion: MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION },
        headers: { "HTTP_HOST" => host })
    end
  end
end
