require "rails_helper"

RSpec.describe "Api::V1::ScanContexts", type: :request do
  let(:event) { create(:event, timezone: "America/New_York") }
  let(:admin) { User.create!(email: "api-contexts@example.com", name: "API Admin", global_role: "global_admin") }
  let(:mobile_token) { MobileToken.generate_for(admin) }

  def auth_headers
    { "Authorization" => "Bearer #{mobile_token.token}" }
  end

  describe "GET /api/v1/events/:event_id/scan_contexts" do
    it "returns schedule times in the event's timezone" do
      event.scan_contexts.create!(
        name: "Dinner",
        starts_at: Time.utc(2026, 7, 15, 22, 0),
        ends_at: Time.utc(2026, 7, 16, 0, 0)
      )

      get "/api/v1/events/#{event.id}/scan_contexts", headers: auth_headers

      expect(response).to have_http_status(:ok)
      dinner = JSON.parse(response.body)["scan_contexts"].find { |c| c["name"] == "Dinner" }
      expect(dinner["starts_at"]).to eq("2026-07-15T18:00:00-04:00")
      expect(dinner["ends_at"]).to eq("2026-07-15T20:00:00-04:00")
    end

    it "returns null schedule fields when unset" do
      event.scan_contexts.create!(name: "Anytime")

      get "/api/v1/events/#{event.id}/scan_contexts", headers: auth_headers

      anytime = JSON.parse(response.body)["scan_contexts"].find { |c| c["name"] == "Anytime" }
      expect(anytime["starts_at"]).to be_nil
      expect(anytime["ends_at"]).to be_nil
    end

    it "returns canonical and deprecated travel pickup fields" do
      event.scan_contexts.create!(name: "Station pickup", is_travel_pickup: true)

      get "/api/v1/events/#{event.id}/scan_contexts", headers: auth_headers

      expect(response).to have_http_status(:ok)
      pickup = JSON.parse(response.body)["scan_contexts"].find { |context| context["name"] == "Station pickup" }
      expect(pickup).to include(
        "is_travel_pickup" => true,
        "is_airport" => true
      )
    end
  end
end
