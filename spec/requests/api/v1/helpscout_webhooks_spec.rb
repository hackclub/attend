require "rails_helper"

RSpec.describe "Api::V1::HelpscoutWebhooks", type: :request do
  let(:secret) { "helpscout-test-secret" }
  let(:service) { instance_double(HelpscoutService, update_customer_property: true) }

  around do |example|
    previous = ENV["HELPSCOUT_WEBHOOK_SECRET"]
    ENV["HELPSCOUT_WEBHOOK_SECRET"] = secret
    example.run
  ensure
    ENV["HELPSCOUT_WEBHOOK_SECRET"] = previous
  end

  before { allow(HelpscoutService).to receive(:new).and_return(service) }

  def deliver(email)
    payload = { customer: { email: email, id: 4242 } }.to_json
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha1", secret, payload))
    post "/api/v1/helpscout_webhooks", params: payload, headers: {
      "Content-Type" => "application/json",
      "X-HelpScout-Event" => "convo.created",
      "X-HelpScout-Signature" => signature
    }
  end

  it "finds the user when the customer typed their address in another case" do
    user = create(:user, email: "robin.vale@example.com")

    deliver(" Robin.Vale@Example.com")

    expect(response).to have_http_status(:ok)
    expect(service).to have_received(:update_customer_property)
      .with(hash_including(customer_id: 4242, value: a_string_ending_with("/admin/users/#{user.id}")))
  end

  it "does nothing for an address no user has" do
    deliver("stranger@example.com")

    expect(response).to have_http_status(:ok)
    expect(service).not_to have_received(:update_customer_property)
  end
end
