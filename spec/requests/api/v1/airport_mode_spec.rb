require "rails_helper"

RSpec.describe "Api::V1::AirportMode", type: :request do
  describe "GET /api/v1/events/:event_id/airport_mode" do
    let(:event) { create(:event, timezone: "America/Los_Angeles") }
    let(:participant) { create(:participant) }
    let(:participant_event) { create(:participant_event, event: event, participant: participant, status: :complete) }

    before do
      event.generate_api_key!
      @api_key = event.api_key
    end

    def auth_headers(key = @api_key)
      { "Authorization" => "Bearer #{key}", "Content-Type" => "application/json" }
    end

    it "returns journeys with UTC ISO times and the arrival airport timezone" do
      travel_record = Travel.create!(
        participant_event: participant_event,
        direction: "inbound",
        mode: "plane"
      )

      arrival_utc = Time.utc(2026, 7, 15, 20, 30, 0)

      TravelLeg.create!(
        travel: travel_record,
        position: 1,
        flight_code: "UA123",
        departure_airport: "JFK",
        arrival_airport: "SFO",
        departure_time: arrival_utc - 5.hours,
        arrival_time: arrival_utc
      )

      get "/api/v1/events/#{event.id}/airport_mode", headers: auth_headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      journey = json["journeys"].first
      expect(journey).to be_present
      # Times are emitted as UTC ISO8601; the client formats them.
      expect(journey["primaryTimeIso"]).to eq("2026-07-15T20:30:00Z")
      # The timezone the client should format the arrival in is the arrival airport's.
      expect(journey["primaryTimezone"]).to eq("America/Los_Angeles")
    end

    it "preserves overnight arrivals (arrival on the day after departure)" do
      travel_record = Travel.create!(
        participant_event: participant_event,
        direction: "inbound",
        mode: "plane"
      )

      # Red-eye: departs 2026-07-15 23:00 UTC, arrives 2026-07-16 09:00 UTC.
      TravelLeg.create!(
        travel: travel_record,
        position: 1,
        flight_code: "OS101",
        departure_airport: "JFK",
        arrival_airport: "VIE",
        departure_time: Time.utc(2026, 7, 15, 23, 0, 0),
        arrival_time: Time.utc(2026, 7, 16, 9, 0, 0)
      )

      get "/api/v1/events/#{event.id}/airport_mode", headers: auth_headers

      json = JSON.parse(response.body)
      leg = json["journeys"].first["legs"].first
      expect(Time.iso8601(leg["arrivalTime"])).to be > Time.iso8601(leg["departureTime"])
    end
  end
end
