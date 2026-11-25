require "rails_helper"

RSpec.describe "Api::V1::CheckinCodes", type: :request do
  let(:event) { create(:event) }
  let(:admin) { User.create!(email: "api-checkin-codes@example.com", name: "API Admin", global_role: "global_admin") }
  let(:mobile_token) { MobileToken.generate_for(admin) }
  let(:signing_key) { CheckinCode.generate_key }

  def auth_headers(token = mobile_token)
    { "Authorization" => "Bearer #{token.token}" }
  end

  describe "GET /api/v1/events/:event_id/checkin_codes" do
    it "gives a scanner the public keys and the cancelled registrations, and nothing more" do
      CheckinCode.keyring = { 1 => signing_key }
      withdrawn = create(:participant_event, event: event, status: "withdrawn")
      rejected = create(:participant_event, event: event, status: "rejected")
      create(:participant_event, event: event, status: "complete")
      create(:participant_event, status: "withdrawn")

      get "/api/v1/events/#{event.id}/checkin_codes", headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.keys).to contain_exactly("signing", "keys", "cancelled")
      expect(body["signing"]).to be(true)
      expect(body["keys"]).to eq("1" => Base64.strict_encode64(signing_key.public_to_der))
      expect(body["cancelled"]).to contain_exactly(withdrawn.id, rejected.id)
      expect(response.body).not_to include(signing_key.private_to_pem.lines[1].strip)
    end

    it "says so while tickets aren't signed" do
      get "/api/v1/events/#{event.id}/checkin_codes", headers: auth_headers

      expect(response.parsed_body).to include("signing" => false, "keys" => {})
    end

    it "refuses someone without access to the event" do
      outsider = User.create!(email: "api-checkin-outsider@example.com", name: "Outsider")

      get "/api/v1/events/#{event.id}/checkin_codes", headers: auth_headers(MobileToken.generate_for(outsider))

      expect(response).to have_http_status(:forbidden)
    end
  end
end
