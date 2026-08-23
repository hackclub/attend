require "rails_helper"

# The MCP OAuth consent screen is rendered by a toolchest *engine* controller
# inside the app's application layout. Engine view contexts resolve
# polymorphic URLs against the engine's route set, which lacks Active
# Storage's resolve mappings — so `image_tag user.avatar.variant(...)` in the
# layout 500'd for any user with an avatar (ATTEND-9X). The layout now routes
# avatar variants through `main_app.url_for`.
RSpec.describe "Toolchest OAuth consent screen", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) do
    create(:user).tap do |u|
      u.avatar.attach(
        io: File.open(file_fixture("headshot.png")),
        filename: "headshot.png",
        content_type: "image/png"
      )
      u.save!
    end
  end

  let(:application) do
    Toolchest::OauthApplication.create!(
      name: "Poke",
      redirect_uri: "https://poke.example.com/api/v1/mcp/callback"
    )
  end

  it "renders for a user with an avatar" do
    sign_in user

    get "/mcp/oauth/authorize", params: {
      response_type: "code",
      client_id: application.uid,
      redirect_uri: application.redirect_uri,
      code_challenge: "x" * 43,
      code_challenge_method: "S256",
      state: "abc123",
      scope: "events:read events:write"
    }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Poke")
  end
end
