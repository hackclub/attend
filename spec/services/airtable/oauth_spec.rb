require "rails_helper"

RSpec.describe Airtable::Oauth do
  include ActiveSupport::Testing::TimeHelpers

  subject(:oauth) { described_class.new }

  let(:token_url) { "https://airtable.com/oauth2/v1/token" }
  let(:token_body) do
    {
      access_token: "fictional-access",
      refresh_token: "fictional-refresh",
      token_type: "Bearer",
      scope: "data.records:write schema.bases:write",
      expires_in: 3600,
      refresh_expires_in: 5_184_000
    }.to_json
  end

  before do
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:airtable, :oauth_client_id).and_return("fictional-client")
    allow(Rails.application.credentials).to receive(:dig).with(:airtable, :oauth_client_secret).and_return("fictional-secret")
  end

  it "builds a PKCE authorize URL with the scopes the sync needs" do
    url = URI.parse(oauth.authorize_url(state: "s" * 32, redirect_uri: "https://example.test/cb", code_challenge: "challenge"))
    params = Rack::Utils.parse_query(url.query)

    expect(url.to_s).to start_with("https://airtable.com/oauth2/v1/authorize?")
    expect(params).to include(
      "client_id" => "fictional-client",
      "response_type" => "code",
      "code_challenge" => "challenge",
      "code_challenge_method" => "S256",
      "redirect_uri" => "https://example.test/cb"
    )
    expect(params["scope"].split).to include("data.records:write", "schema.bases:write")
  end

  it "exchanges a code using Basic auth and returns the token's lifetimes" do
    stub = stub_request(:post, token_url)
      .with(
        headers: { "Authorization" => "Basic #{Base64.urlsafe_encode64('fictional-client:fictional-secret')}" },
        body: { grant_type: "authorization_code", code: "abc", redirect_uri: "https://example.test/cb", code_verifier: "v" * 43 }
      )
      .to_return(status: 200, body: token_body)

    freeze_time do
      token = oauth.exchange_code(code: "abc", redirect_uri: "https://example.test/cb", code_verifier: "v" * 43)

      expect(stub).to have_been_requested
      expect(token.access_token).to eq("fictional-access")
      expect(token.refresh_token).to eq("fictional-refresh")
      expect(token.expires_at).to eq(1.hour.from_now)
      expect(token.refresh_expires_at).to eq(60.days.from_now)
    end
  end

  it "tells the organiser to reconnect when the refresh token is dead" do
    stub_request(:post, token_url)
      .to_return(status: 400, body: { error: "invalid_grant", error_description: "refresh token expired" }.to_json)

    expect { oauth.refresh("fictional-refresh") }
      .to raise_error(Airtable::AuthenticationError, /Reconnect Airtable/)
  end

  it "lists every granted base across pages" do
    stub_request(:get, "https://api.airtable.com/v0/meta/bases")
      .to_return(status: 200, body: { bases: [ { id: "appOne", name: "One", permissionLevel: "create" } ], offset: "next" }.to_json)
    stub_request(:get, "https://api.airtable.com/v0/meta/bases?offset=next")
      .to_return(status: 200, body: { bases: [ { id: "appTwo", name: "Two" } ] }.to_json)

    expect(oauth.list_bases("fictional-access")).to eq([
      { "id" => "appOne", "name" => "One" },
      { "id" => "appTwo", "name" => "Two" }
    ])
  end

  it "is not configured without a client secret" do
    allow(Rails.application.credentials).to receive(:dig).with(:airtable, :oauth_client_secret).and_return(nil)

    expect(oauth).not_to be_configured
  end
end
