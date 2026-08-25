require "rails_helper"

# MCP is a staff surface: non-staff accounts (participants, guardians, anyone
# signed in with no event or series role) can't connect a client, can't call a
# tool, and don't see the Connections section on their profile.
RSpec.describe "MCP staff-only access", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:staff) { create(:user, global_role: "global_admin") }
  let(:non_staff) { create(:user) }
  # /dashboard/profile is a participant-or-staff page; give the non-staff user one.
  let!(:non_staff_participant) { create(:participant, user: non_staff) }

  let(:application) do
    Toolchest::OauthApplication.create!(
      name: "Poke",
      redirect_uri: "https://poke.example.com/api/v1/mcp/callback"
    )
  end

  def consent_params(overrides = {})
    {
      response_type: "code",
      client_id: application.uid,
      redirect_uri: application.redirect_uri,
      code_challenge: "x" * 43,
      code_challenge_method: "S256",
      state: "abc123",
      scope: "events:read"
    }.merge(overrides)
  end

  describe "the OAuth consent screen" do
    it "bounces a non-staff user back to the client with access_denied" do
      sign_in non_staff

      get "/mcp/oauth/authorize", params: consent_params

      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to start_with(application.redirect_uri)
      expect(response.headers["Location"]).to include("error=access_denied")
    end

    it "refuses to issue a grant to a non-staff user who posts the form anyway" do
      sign_in non_staff

      expect {
        post "/mcp/oauth/authorize", params: consent_params(
          scope: [ "events:read" ],
          original_scope: "events:read"
        )
      }.not_to change(Toolchest::OauthAccessGrant, :count)

      expect(response.headers["Location"]).to include("error=access_denied")
    end

    it "still renders for a staff user" do
      sign_in staff

      get "/mcp/oauth/authorize", params: consent_params

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Poke")
    end

    it "renders for someone whose only role is on a single event" do
      user = create(:user)
      user.event_role_assignments.create!(event: event, role: :ops)
      sign_in user

      get "/mcp/oauth/authorize", params: consent_params

      expect(response).to have_http_status(:ok)
    end
  end

  describe "tool calls" do
    def call_tool(user, name)
      token = Toolchest::OauthAccessToken.create_for(
        application: application,
        resource_owner_id: user.id,
        scopes: "events:read"
      )

      post "/mcp",
        params: {
          jsonrpc: "2.0", id: 1,
          method: "tools/call",
          params: { name: name, arguments: {} }
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "ACCEPT" => "application/json, text/event-stream",
          "HTTP_AUTHORIZATION" => "Bearer #{token.raw_token}"
        }
    end

    # A token issued while someone was staff keeps resolving until it expires,
    # so the toolbox itself has to refuse rather than run with a nil user.
    it "refuses every tool call from a non-staff token holder" do
      call_tool(non_staff, "events_index")

      expect(response.body).to include("MCP access is limited to Attend staff")
    end

    it "lets a staff token holder through" do
      event
      call_tool(staff, "events_index")

      expect(response.body).not_to include("MCP access is limited to Attend staff")
      expect(response.body).to include(event.name)
    end
  end

  describe "the Connections section on /dashboard/profile" do
    it "is hidden for a non-staff user with nothing connected" do
      sign_in non_staff

      get dashboard_profile_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("#connections")
    end

    # Someone who connected a client and later lost their role still needs a way
    # to clear the (now dead) connection out.
    it "stays visible for a non-staff user who still has a live connection" do
      Toolchest::OauthAccessToken.create_for(
        application: application,
        resource_owner_id: non_staff.id,
        scopes: "events:read"
      )
      sign_in non_staff

      get dashboard_profile_path

      expect(response.body).to include("Poke")
      expect(response.body).to include("only available to Attend staff")
    end

    it "is visible for a staff user" do
      sign_in staff

      get dashboard_profile_path

      expect(response.body).to include("#connections")
    end
  end
end
