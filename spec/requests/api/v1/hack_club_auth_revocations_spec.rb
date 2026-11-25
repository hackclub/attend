require "rails_helper"

RSpec.describe "Hack Club Auth session revoker", type: :request do
  let(:secret) { "test-revoker-secret" }
  let(:path) { "/api/v1/webhooks/hack_club_auth" }
  let(:headers) { { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" } }
  let!(:user) do
    create(:user, email: "organizer@example.com",
      oidc_claims: { "slack_id" => "U0EXAMPLE1", "groups" => [ User::SELF_SERVE_EVENTS_GROUP ] })
  end

  around do |example|
    ENV["HACK_CLUB_AUTH_REVOKER_SECRET"] = secret
    example.run
  ensure
    ENV.delete("HACK_CLUB_AUTH_REVOKER_SECRET")
  end

  it "drops the groups claim, and with it self-serve access, keeping the other claims" do
    post path, params: { email: "Organizer@Example.com" }.to_json, headers: headers

    expect(response).to have_http_status(:no_content)
    user.reload
    expect(user.oidc_claims).to eq("slack_id" => "U0EXAMPLE1")
    expect(user).not_to be_self_serve_event_creator
    expect(user).not_to be_admin
  end

  it "answers 2xx for an address nobody here has, so HCA doesn't keep retrying" do
    post path, params: { email: "nobody@example.com" }.to_json, headers: headers

    expect(response).to have_http_status(:no_content)
  end

  it "answers 2xx to a request with no email, changing nothing" do
    post path, params: { email: "  " }.to_json, headers: headers
    expect(response).to have_http_status(:no_content)

    post path, params: {}.to_json, headers: headers
    expect(response).to have_http_status(:no_content)

    expect(user.reload).to be_self_serve_event_creator
  end

  it "refuses a wrong or missing secret" do
    post path, params: { email: user.email }.to_json, headers: headers.merge("Authorization" => "Bearer wrong")
    expect(response).to have_http_status(:unauthorized)

    post path, params: { email: user.email }.to_json, headers: headers.except("Authorization")
    expect(response).to have_http_status(:unauthorized)

    expect(user.reload).to be_self_serve_event_creator
  end

  it "refuses everything while no secret is configured" do
    ENV.delete("HACK_CLUB_AUTH_REVOKER_SECRET")
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:hack_club, :revoker_secret).and_return(nil)

    post path, params: { email: user.email }.to_json, headers: headers

    expect(response).to have_http_status(:unauthorized)
    expect(user.reload).to be_self_serve_event_creator
  end
end
