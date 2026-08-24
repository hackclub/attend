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

  # The consent screen also collects the per-connection restrictions: which
  # events the client may reach, and whether its responses are anonymized.
  # See ToolchestConnectionSettings and McpConnectionSetting.
  describe "connection restrictions" do
    let!(:assemble) { create(:event, name: "Assemble") }
    let!(:undercity) { create(:event, name: "Undercity") }
    let!(:elsewhere) { create(:event, name: "Elsewhere") }

    before do
      create(:event_role_assignment, user: user, event: assemble, role: "event_admin")
      create(:event_role_assignment, user: user, event: undercity, role: "ops")
      sign_in user
    end

    def settings = McpConnectionSetting.find_by(application_id: application.id, resource_owner_id: user.id.to_s)

    def authorize_params(overrides = {})
      consent_params(scope: [ "events:read" ], original_scope: "events:read").merge(overrides)
    end

    it "offers only the events the user can delegate" do
      get "/mcp/oauth/authorize", params: consent_params

      expect(response.body).to include("Assemble")
      expect(response.body).to include("Undercity")
      expect(response.body).not_to include("Elsewhere")
      expect(response.body).to include("Anonymise everything")
    end

    it "defaults to every event and no anonymisation" do
      post "/mcp/oauth/authorize", params: authorize_params

      expect(response).to have_http_status(:found)
      expect(settings).to be_all_events
      expect(settings).not_to be_anonymize
    end

    it "restricts the connection to the events that were picked" do
      post "/mcp/oauth/authorize", params: authorize_params(
        mcp_event_scope: "selected", mcp_event_ids: [ assemble.id ]
      )

      expect(response).to have_http_status(:found)
      expect(settings).not_to be_all_events
      expect(settings.permitted_event_ids).to contain_exactly(assemble.id)
    end

    it "ignores events the user cannot reach" do
      post "/mcp/oauth/authorize", params: authorize_params(
        mcp_event_scope: "selected", mcp_event_ids: [ assemble.id, elsewhere.id ]
      )

      expect(settings.permitted_event_ids).to contain_exactly(assemble.id)
    end

    it "re-renders instead of issuing a code when specific events are asked for but none picked" do
      post "/mcp/oauth/authorize", params: authorize_params(mcp_event_scope: "selected")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Pick at least one event")
      expect(settings).to be_nil
      expect(Toolchest::OauthAccessGrant.count).to eq(0)
    end

    it "records anonymisation with where it came from" do
      post "/mcp/oauth/authorize", params: authorize_params(mcp_anonymize: "1")

      expect(settings).to be_anonymize
      expect(settings.anonymize_enabled_by).to eq("consent")
    end

    it "saves nothing when the user denies" do
      delete "/mcp/oauth/authorize", params: consent_params

      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to include("error=access_denied")
      expect(settings).to be_nil
    end

    # Re-authorising is the only way to widen a connection, so the form starts
    # from what it already has rather than from wide open.
    it "pre-selects the connection's current restrictions" do
      existing = McpConnectionSetting.create!(application: application, resource_owner_id: user.id.to_s)
      existing.narrow_events!([ assemble.id ])
      existing.anonymize!(:consent)

      get "/mcp/oauth/authorize", params: consent_params

      expect(response.body).to match(/id="mcp_event_#{assemble.id}"[^>]*checked="checked"/)
      expect(response.body).to match(/id="mcp_anonymize"[^>]*checked="checked"/)
      expect(response.body).not_to match(/id="mcp_event_#{undercity.id}"[^>]*checked="checked"/)
    end

    it "lets a re-authorisation widen what a connection can see" do
      existing = McpConnectionSetting.create!(application: application, resource_owner_id: user.id.to_s)
      existing.narrow_events!([ assemble.id ])
      existing.anonymize!(:consent)

      post "/mcp/oauth/authorize", params: authorize_params

      expect(settings).to be_all_events
      expect(settings).not_to be_anonymize
    end
  end
end
