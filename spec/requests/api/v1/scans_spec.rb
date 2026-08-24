require "rails_helper"

RSpec.describe "Api::V1::Scans", type: :request do
  let(:event) { create(:event) }
  let(:admin) { User.create!(email: "api-scans@example.com", name: "API Admin", global_role: "global_admin") }
  let(:mobile_token) { MobileToken.generate_for(admin) }

  def auth_headers
    { "Authorization" => "Bearer #{mobile_token.token}" }
  end

  describe "GET /api/v1/events/:event_id/scans with since" do
    it "caps the response and marks it resumable" do
      stub_const("Api::V1::ScansController::SINCE_SYNC_LIMIT", 3)

      pe = create(:participant_event, event: event)
      context = event.scan_contexts.create!(name: "Check-in", checks_in: true)
      5.times { |i| pe.scans.create!(scan_context: context, user: admin, scanned_at: (10 - i).minutes.ago) }

      get "/api/v1/events/#{event.id}/scans",
        params: { since: 1.day.ago.iso8601 }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["scans"].size).to eq(3)
      expect(json["has_more"]).to be(true)

      # synced_at resumes after the last delivered scan: a follow-up poll
      # returns the remaining scans instead of losing them.
      get "/api/v1/events/#{event.id}/scans",
        params: { since: json["synced_at"] }, headers: auth_headers

      followup = JSON.parse(response.body)
      expect(followup["scans"].size).to eq(2)
      expect(followup["has_more"]).to be(false)
    end

    it "returns everything with has_more false when under the cap" do
      pe = create(:participant_event, event: event)
      context = event.scan_contexts.create!(name: "Check-in", checks_in: true)
      2.times { pe.scans.create!(scan_context: context, user: admin, scanned_at: 5.minutes.ago) }

      get "/api/v1/events/#{event.id}/scans",
        params: { since: 1.day.ago.iso8601 }, headers: auth_headers

      json = JSON.parse(response.body)
      expect(json["scans"].size).to eq(2)
      expect(json["has_more"]).to be(false)
    end
  end

  describe "POST /api/v1/events/:event_id/scans" do
    it "marks the final inbound flight leg for an explicit travel pickup scan" do
      participant_event = create(:participant_event, event: event)
      pickup = event.scan_contexts.create!(name: "Station pickup", checks_in: false, is_travel_pickup: true)
      travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "plane")
      leg = create(:travel_leg, travel: travel, departure_airport: "SFO", arrival_airport: "BOS")

      post "/api/v1/events/#{event.id}/scans",
        params: { participant_id: participant_event.id, scan_context_id: pickup.id }.to_json,
        headers: auth_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(leg.reload).to be_travel_picked_up
    end
  end
end
