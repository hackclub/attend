require "rails_helper"

# The Connections section on /dashboard/profile lists the MCP clients a user
# has authorized (one row per application, scopes merged across tokens) and
# lets them disconnect one, which revokes every live token and grant.
RSpec.describe "Dashboard MCP connections", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user) }
  let!(:participant) { create(:participant, user: user) }

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
end
