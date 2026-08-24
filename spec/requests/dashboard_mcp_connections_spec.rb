require "rails_helper"

# The Connections section on /dashboard/profile lists the MCP clients a user
# has authorized (one row per application, scopes merged across tokens) and
# lets them disconnect one, which revokes every live token and grant.
RSpec.describe "Dashboard MCP connections", type: :request do
  include Devise::Test::IntegrationHelpers

  # The Connections section is staff-only (non-staff only see it to clean up a
  # connection made before they lost the role).
  let(:user) { create(:user) }
  let!(:participant) { create(:participant, user: user) }
  let!(:staff_event) { create(:event) }
  let!(:staff_role) { create(:event_role_assignment, user: user, event: staff_event, role: "event_admin") }

  let(:application) do
    Toolchest::OauthApplication.create!(
      name: "Poke",
      redirect_uri: "https://poke.example.com/api/v1/mcp/callback"
    )
  end

  before { sign_in user }

  def create_token(scopes:, resource_owner: user)
    Toolchest::OauthAccessToken.create_for(
      application: application,
      resource_owner_id: resource_owner.id,
      scopes: scopes
    )
  end

  describe "GET /dashboard/profile" do
    it "lists a connected application with its merged scopes" do
      create_token(scopes: "events:read")
      create_token(scopes: "events:read participants:read")

      get dashboard_profile_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Connections")
      expect(response.body).to include("Poke")
      expect(response.body).to include("events:read")
      expect(response.body).to include("participants:read")
    end

    it "does not list revoked connections or other users' connections" do
      create_token(scopes: "events:read").revoke!
      other_user = create(:user)
      create_token(scopes: "events:read", resource_owner: other_user)

      get dashboard_profile_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Nothing is connected to your account.")
    end

    it "only lets former staff with a legacy connection disconnect it" do
      create_token(scopes: "events:read")
      user.event_role_assignments.destroy_all

      get dashboard_profile_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("MCP is only available to Attend staff")
      expect(response.body).to include("Disconnect")
      expect(response.body).not_to include('value="Anonymise"')
      expect(response.body).not_to include(">Limit to specific events<")
    end
  end

  describe "DELETE /dashboard/mcp_connections/:id" do
    it "revokes the user's tokens and grants for the application" do
      token = create_token(scopes: "events:read")
      grant = Toolchest::OauthAccessGrant.create_for(
        application: application,
        resource_owner_id: user.id,
        redirect_uri: application.redirect_uri,
        scopes: "events:read"
      )
      other_user = create(:user)
      other_token = create_token(scopes: "events:read", resource_owner: other_user)

      delete dashboard_mcp_connection_path(application)

      expect(response).to redirect_to(dashboard_profile_path(anchor: "connections"))
      expect(token.reload).to be_revoked
      expect(grant.reload).to be_revoked
      expect(other_token.reload).not_to be_revoked
    end

    it "handles an unknown application id" do
      delete dashboard_mcp_connection_path(id: 999_999)

      expect(response).to redirect_to(dashboard_profile_path(anchor: "connections"))
      expect(flash[:alert]).to eq("Connection not found.")
    end
  end

  # Connections can be tightened in place but never loosened: widening means
  # disconnecting and re-authorising, so it goes back through consent.
  describe "PATCH /dashboard/mcp_connections/:id" do
    let!(:assemble) { create(:event, name: "Assemble") }
    let!(:undercity) { create(:event, name: "Undercity") }
    let!(:elsewhere) { create(:event, name: "Elsewhere") }

    before do
      create(:event_role_assignment, user: user, event: assemble, role: "event_admin")
      create(:event_role_assignment, user: user, event: undercity, role: "ops")
      create_token(scopes: "events:read")
    end

    def settings = McpConnectionSetting.find_by(application_id: application.id, resource_owner_id: user.id.to_s)

    it "narrows an unrestricted connection to specific events" do
      patch update_dashboard_mcp_connection_path(application),
        params: { event_scope: "selected", mcp_event_ids: [ assemble.id ] }

      expect(response).to redirect_to(dashboard_profile_path(anchor: "connections"))
      expect(settings.permitted_event_ids).to contain_exactly(assemble.id)
      expect(flash[:notice]).to include("limited to Assemble")
    end

    it "cannot widen a connection that is already restricted" do
      existing = McpConnectionSetting.create!(application: application, resource_owner_id: user.id.to_s)
      existing.narrow_events!([ assemble.id ])

      patch update_dashboard_mcp_connection_path(application),
        params: { event_scope: "selected", mcp_event_ids: [ assemble.id, undercity.id ] }

      expect(settings.permitted_event_ids).to contain_exactly(assemble.id)
    end

    it "ignores events the user cannot reach" do
      patch update_dashboard_mcp_connection_path(application),
        params: { event_scope: "selected", mcp_event_ids: [ assemble.id, elsewhere.id ] }

      expect(settings.permitted_event_ids).to contain_exactly(assemble.id)
    end

    it "refuses to narrow a connection down to nothing" do
      patch update_dashboard_mcp_connection_path(application), params: { event_scope: "selected" }

      expect(flash[:alert]).to include("Pick at least one event")
      expect(settings).to be_all_events
    end

    it "turns anonymisation on" do
      patch update_dashboard_mcp_connection_path(application), params: { mcp_anonymize: "1" }

      expect(settings).to be_anonymize
      expect(settings.anonymize_enabled_by).to eq("dashboard")
      expect(flash[:notice]).to include("anonymised and read-only")
    end

    it "never turns anonymisation back off" do
      existing = McpConnectionSetting.create!(application: application, resource_owner_id: user.id.to_s)
      existing.anonymize!(:consent)

      patch update_dashboard_mcp_connection_path(application),
        params: { mcp_anonymize: "0", anonymize: "false" }

      expect(settings).to be_anonymize
    end

    it "handles an unknown application id" do
      patch update_dashboard_mcp_connection_path(id: 999_999), params: { mcp_anonymize: "1" }

      expect(flash[:alert]).to eq("Connection not found.")
    end

    it "does not let former staff tighten a legacy connection" do
      user.event_role_assignments.destroy_all

      patch update_dashboard_mcp_connection_path(application), params: { mcp_anonymize: "1" }

      expect(response).to redirect_to(dashboard_profile_path)
      expect(settings).to be_nil
    end
  end

  describe "GET /dashboard/profile" do
    it "shows a connection's event scope and anonymisation state" do
      event = create(:event, name: "Assemble")
      create(:event_role_assignment, user: user, event: event, role: "event_admin")
      create_token(scopes: "events:read")
      settings = McpConnectionSetting.create!(application: application, resource_owner_id: user.id.to_s)
      settings.narrow_events!([ event.id ])
      settings.anonymize!(:consent)

      get dashboard_profile_path

      expect(response.body).to include("Anonymised")
      expect(response.body).to include("initials only, no contact details, read-only")
    end
  end
end
