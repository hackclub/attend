require "rails_helper"

# Drives IncidentsToolbox through the MCP endpoint. Every tool but index renders
# the full incident, so this is what catches a renamed association there.
RSpec.describe "MCP incident tools", type: :request do
  let(:event) { create(:event) }
  let(:user) { create(:user).tap { |u| EventRoleAssignment.create!(user: u, event: event, role: "limited") } }

  let(:access_token) do
    Toolchest::OauthAccessToken.create_for(
      application: Toolchest::OauthApplication.create!(name: "Spec client", redirect_uri: "https://client.example.com/callback"),
      resource_owner_id: user.id,
      scopes: "safeguarding:read safeguarding:write"
    )
  end

  def call_tool(name, arguments)
    post "/mcp",
      params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json,
      headers: {
        "Authorization" => "Bearer #{access_token.raw_token}",
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream"
      }

    body = JSON.parse(response.body)
    expect(body["error"]).to be_nil
    expect(body.dig("result", "isError")).to be_falsey
    JSON.parse(body.dig("result", "content").map { |part| part["text"] }.join)
  end

  it "creates, shows and comments on an incident" do
    created = call_tool("incidents_create",
      "event_slug" => event.slug, "category" => "behavior", "severity" => "s3", "summary" => "Lost badge")
    expect(created["visible_to_roles"]).to eq(Incident::DEFAULT_VISIBLE_TO_ROLES)
    expect(created["reported_by"]).to eq(user.display_name_or_fallback)

    # Not shared with Limited, but the reporter can still read and comment on it.
    id = created.fetch("id")
    expect(call_tool("incidents_show", "incident_id" => id)["summary"]).to eq("Lost badge")

    commented = call_tool("incidents_add_comment", "incident_id" => id, "body" => "Found it")
    expect(commented["comments"].map { |c| c["body"] }).to eq([ "Found it" ])
  end
end
