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

  def consent_params(overrides = {})
    {
      response_type: "code",
      client_id: application.uid,
      redirect_uri: application.redirect_uri,
      code_challenge: "x" * 43,
      code_challenge_method: "S256",
      state: "abc123",
      scope: "events:read events:write"
    }.merge(overrides)
  end

  it "renders for a user with an avatar" do
    sign_in user

    get "/mcp/oauth/authorize", params: consent_params

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Poke")
  end

  # The Authorize button posts back to the app, which 302s to the client's
  # redirect_uri. Browsers enforce the consent page's form-action across that
  # redirect chain, so the validated redirect origin has to be in the header
  # or clicking Authorize silently does nothing (ATTEND: Poke connect bug).
  it "allowlists the client's redirect_uri origin in form-action" do
    sign_in user

    get "/mcp/oauth/authorize", params: consent_params

    form_action = response.headers["Content-Security-Policy"][/form-action[^;]*/]
    expect(form_action).to include("'self'")
    expect(form_action).to include("https://poke.example.com")
  end

  it "does not leak the redirect origin into other pages' form-action" do
    sign_in user

    get "/dashboard/profile"

    form_action = response.headers["Content-Security-Policy"][/form-action[^;]*/]
    expect(form_action).not_to include("poke.example.com")
  end

  it "issues a code and redirects to the client when the user authorizes" do
    sign_in user

    post "/mcp/oauth/authorize", params: consent_params(
      scope: [ "events:read", "events:write" ],
      original_scope: "events:read events:write"
    )

    expect(response).to have_http_status(:found)
    location = response.headers["Location"]
    expect(location).to start_with("https://poke.example.com/api/v1/mcp/callback?")
    expect(location).to include("state=abc123")
    expect(location).to match(/code=[\w-]+/)
  end
end
