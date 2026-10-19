require "rails_helper"

RSpec.describe "Connected accounts", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let!(:participant) { create(:participant, user: user, email: user.email) }
  let(:return_to) { "/onboarding/accounts?event_id=abc" }

  before do
    stub_account_linking_credentials
    sign_in user
  end

  # Starts the flow and returns the state the provider would echo back.
  def start(provider, return_to: self.return_to)
    post connect_account_path(provider: provider), params: { return_to: return_to }
    Rack::Utils.parse_query(URI.parse(response.location).query)["state"]
  end

  def stub_github(token_body: { access_token: "gho_token", scope: "read:user", token_type: "bearer" })
    stub_request(:post, "https://github.com/login/oauth/access_token")
      .to_return(status: 200, body: token_body.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://api.github.com/user")
      .with(headers: { "Authorization" => "Bearer gho_token" })
      .to_return(status: 200, body: { id: 583231, login: "octocat", name: "The Octocat", html_url: "https://github.com/octocat" }.to_json)
  end

  describe "GitHub" do
    it "sends the participant to GitHub with a state and PKCE challenge" do
      post connect_account_path(provider: "github"), params: { return_to: return_to }

      uri = URI.parse(response.location)
      query = Rack::Utils.parse_query(uri.query)
      expect(uri.host).to eq("github.com")
      expect(query).to include("client_id" => "gh-client", "scope" => "read:user", "code_challenge_method" => "S256")
      expect(query["state"]).to be_present
      expect(query["redirect_uri"]).to eq(connected_account_callback_url(provider: "github"))
    end

    it "links the account and keeps the token" do
      stub_github
      state = start("github")

      get connected_account_callback_path(provider: "github"), params: { code: "abc", state: state }

      expect(response).to redirect_to(return_to)
      expect(flash[:notice]).to eq("GitHub connected as octocat.")
      account = participant.connected_accounts.github.sole
      expect(account).to have_attributes(uid: "583231", username: "octocat", access_token: "gho_token", scope: "read:user")
      expect(participant.reload.public_profile_github).to eq("octocat")
      expect(a_request(:post, "https://github.com/login/oauth/access_token")
        .with(body: hash_including("code" => "abc", "client_secret" => "gh-secret", "code_verifier" => /\A[\w-]{43,128}\z/))).to have_been_made
    end

    it "keeps a GitHub handle the participant already set on their profile" do
      participant.update_columns(public_profile_github: "someone-else")
      stub_github
      state = start("github")

      get connected_account_callback_path(provider: "github"), params: { code: "abc", state: state }

      expect(participant.reload.public_profile_github).to eq("someone-else")
    end

    it "rejects a callback whose state doesn't match" do
      start("github")

      get connected_account_callback_path(provider: "github"), params: { code: "abc", state: "forged" }

      expect(response).to redirect_to(return_to)
      expect(flash[:alert]).to include("expired")
      expect(participant.connected_accounts).to be_empty
    end

    it "rejects a callback with no flow in progress" do
      get connected_account_callback_path(provider: "github"), params: { code: "abc", state: "anything" }

      expect(response).to redirect_to(dashboard_path)
      expect(participant.connected_accounts).to be_empty
    end

    it "only accepts a state once" do
      stub_github
      state = start("github")
      get connected_account_callback_path(provider: "github"), params: { code: "abc", state: state }
      participant.connected_accounts.destroy_all

      get connected_account_callback_path(provider: "github"), params: { code: "abc", state: state }

      expect(participant.connected_accounts).to be_empty
    end

    it "rejects an expired flow" do
      state = start("github")

      travel 11.minutes do
        get connected_account_callback_path(provider: "github"), params: { code: "abc", state: state }
      end

      expect(flash[:alert]).to include("expired")
      expect(participant.connected_accounts).to be_empty
    end

    it "says so when the participant cancels on GitHub" do
      state = start("github")

      get connected_account_callback_path(provider: "github"), params: { error: "access_denied", state: state }

      expect(response).to redirect_to(return_to)
      expect(flash[:alert]).to eq("GitHub wasn't connected.")
    end

    it "handles GitHub rejecting the code" do
      stub_github(token_body: { error: "bad_verification_code", error_description: "The code passed is incorrect or expired." })
      state = start("github")

      get connected_account_callback_path(provider: "github"), params: { code: "stale", state: state }

      expect(response).to redirect_to(return_to)
      expect(flash[:alert]).to include("couldn't connect your GitHub account")
      expect(participant.connected_accounts).to be_empty
    end

    it "never sends the participant to another host afterwards" do
      stub_github
      state = start("github", return_to: "https://evil.example/onboarding")

      get connected_account_callback_path(provider: "github"), params: { code: "abc", state: state }

      expect(response).to redirect_to(dashboard_path)
    end

    it "explains when GitHub linking isn't configured" do
      stub_account_linking_credentials(github: false)

      post connect_account_path(provider: "github"), params: { return_to: return_to }

      expect(response).to redirect_to(return_to)
      expect(flash[:alert]).to include("isn't set up")
    end

    it "disconnects and revokes only that token" do
      participant.connected_accounts.create!(provider: "github", uid: "1", username: "octocat", access_token: "gho_token", connected_at: Time.current)
      revoke = stub_request(:delete, "https://api.github.com/applications/gh-client/token")
        .with(body: { access_token: "gho_token" }.to_json)
        .to_return(status: 204)

      delete disconnect_account_path(provider: "github"), params: { return_to: return_to }

      expect(response).to redirect_to(return_to)
      expect(participant.connected_accounts.reload).to be_empty
      expect(revoke).to have_been_requested
    end

    it "still disconnects when GitHub can't be reached" do
      participant.connected_accounts.create!(provider: "github", uid: "1", username: "octocat", access_token: "gho_token", connected_at: Time.current)
      stub_request(:delete, "https://api.github.com/applications/gh-client/token").to_timeout

      delete disconnect_account_path(provider: "github"), params: { return_to: return_to }

      expect(participant.connected_accounts.reload).to be_empty
    end
  end

  describe "itch.io" do
    def stub_itch_token
      stub_request(:post, "https://api.itch.io/oauth/token")
        .with(body: hash_including("grant_type" => "authorization_code", "client_id" => "itch-client", "code" => "xyz"))
        .to_return(status: 200, body: { access_token: "itch_token", token_type: "bearer", scope: "profile:me profile:games game:view:uploads" }.to_json)
    end

    it "uses the code flow with PKCE" do
      post connect_account_path(provider: "itch"), params: { return_to: return_to }

      uri = URI.parse(response.location)
      query = Rack::Utils.parse_query(uri.query)
      expect(uri.host).to eq("itch.io")
      expect(query).to include("response_type" => "code", "scope" => "profile:me profile:games game:view:uploads", "code_challenge_method" => "S256")
    end

    it "links the account" do
      stub_itch_token
      stub_request(:get, "https://api.itch.io/profile")
        .with(headers: { "Authorization" => "Bearer itch_token" })
        .to_return(status: 200, body: { user: { id: 29789, username: "maker", display_name: "Maker", url: "https://maker.itch.io" } }.to_json)
      state = start("itch")

      get connected_account_callback_path(provider: "itch"), params: { code: "xyz", state: state }

      expect(flash[:notice]).to eq("itch.io connected as maker.")
      expect(participant.connected_accounts.itch.sole).to have_attributes(uid: "29789", access_token: "itch_token", scope: "profile:me profile:games game:view:uploads")
      expect(a_request(:post, "https://api.itch.io/oauth/token").with(body: hash_including("code_verifier" => /\A[\w-]{43,128}\z/))).to have_been_made
    end

    it "handles itch.io's errors array" do
      stub_itch_token
      stub_request(:get, "https://api.itch.io/profile").to_return(status: 200, body: { errors: [ "invalid key" ] }.to_json)
      state = start("itch")

      get connected_account_callback_path(provider: "itch"), params: { code: "xyz", state: state }

      expect(flash[:alert]).to include("couldn't connect your itch.io account")
      expect(participant.connected_accounts).to be_empty
    end
  end

  it "requires signing in" do
    sign_out user

    post connect_account_path(provider: "github")

    expect(response).to have_http_status(:redirect)
    expect(response.location).not_to include("github.com")
  end
end
