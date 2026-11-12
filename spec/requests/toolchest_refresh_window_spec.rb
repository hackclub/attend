require "rails_helper"

# Toolchest ties a refresh token's life to its 2-hour access token. Attend lets
# it outlive the access token so idle MCP clients can refresh instead of
# re-running the OAuth flow. See config/initializers/toolchest_refresh_window.rb.
RSpec.describe "MCP OAuth refresh window", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:application) do
    Toolchest::OauthApplication.create!(name: "Test Client", redirect_uri: "https://client.example.com/callback")
  end
  let!(:token) do
    Toolchest::OauthAccessToken.create_for(
      application: application,
      resource_owner_id: user.id.to_s,
      scopes: "events:read"
    )
  end

  def refresh(raw = token.raw_refresh_token)
    post "/mcp/oauth/token", params: { grant_type: "refresh_token", refresh_token: raw }
  end

  it "refreshes an access token that has already expired" do
    travel 3.hours do
      refresh

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["access_token"]).to be_present
      expect(body["refresh_token"]).to be_present
      expect(body["scope"]).to eq("events:read")
      expect(token.reload).to be_revoked

      fresh = Toolchest::OauthAccessToken.find_by_token(body["access_token"])
      expect(fresh.resource_owner_id).to eq(user.id.to_s)
      expect(fresh).to be_accessible
    end
  end

  it "still refreshes near the end of the window" do
    travel ToolchestRefreshWindow::REFRESH_TOKEN_LIFETIME do
      refresh
      expect(response).to have_http_status(:ok)
    end
  end

  it "rejects a refresh token past the window" do
    travel ToolchestRefreshWindow::REFRESH_TOKEN_LIFETIME + 3.hours do
      refresh
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_grant")
    end
  end

  it "rejects a revoked refresh token even within the window" do
    token.revoke!

    refresh
    expect(response.parsed_body["error"]).to eq("invalid_grant")
  end

  it "rejects a refresh token that has already been used" do
    refresh
    expect(response).to have_http_status(:ok)

    refresh
    expect(response.parsed_body["error"]).to eq("invalid_grant")
  end

  it "rejects a missing refresh token instead of erroring" do
    post "/mcp/oauth/token", params: { grant_type: "refresh_token" }
    expect(response.parsed_body["error"]).to eq("invalid_grant")
  end

  it "does not let an expired access token authenticate" do
    travel 3.hours do
      expect(Toolchest::OauthAccessToken.find_by_token(token.raw_token)).to be_nil
    end
  end
end
