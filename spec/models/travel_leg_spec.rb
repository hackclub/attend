require 'rails_helper'

RSpec.describe TravelLeg, type: :model do
  describe "#fetch_known_flight_data!" do
    let(:participant_event) { create(:participant_event) }
    let(:travel) { Travel.create!(participant_event: participant_event, direction: "inbound", mode: "plane") }
    let(:leg) do
      travel.travel_legs.create!(
        position: 0,
        flight_code: "AA2365",
        departure_airport: "BTV",
        arrival_airport: "PHL",
        departure_time: Time.utc(2026, 7, 13, 17, 12),
        arrival_time: Time.utc(2026, 7, 13, 18, 40),
        oag_schedule_instance_key: "stale-through-flight-key"
      )
    end

    it "drops a stale key whose instance departs from a different airport" do
      through_flight = {
        "departure" => { "airport" => { "iata" => "PHL", "icao" => "KPHL" } },
        "arrival" => { "airport" => { "iata" => "PHL", "icao" => "KPHL" } },
        "scheduleInstanceKey" => "stale-through-flight-key"
      }
      allow(FlightTrackingService).to receive(:fetch_flight_by_id).and_return(through_flight)

      expect(leg.fetch_known_flight_data!).to be_nil
      expect(leg.reload.oag_schedule_instance_key).to be_nil
    end

    it "keeps the key and parses when the departure airport matches" do
      segment = {
        "departure" => {
          "airport" => { "iata" => "BTV", "icao" => "KBTV" },
          "date" => { "utc" => "2026-07-13" }, "time" => { "utc" => "17:12" }
        },
        "arrival" => {
          "airport" => { "iata" => "PHL", "icao" => "KPHL" },
          "date" => { "utc" => "2026-07-13" }, "time" => { "utc" => "18:40" }
        },
        "carrier" => { "iata" => "AA" },
        "flightNumber" => 2365,
        "scheduleInstanceKey" => "stale-through-flight-key"
      }
      allow(FlightTrackingService).to receive(:fetch_flight_by_id).and_return(segment)

      parsed = leg.fetch_known_flight_data!

      expect(parsed[:scheduled_departure]).to eq("2026-07-13T17:12:00Z")
      expect(leg.reload.oag_schedule_instance_key).to eq("stale-through-flight-key")
    end
  end
end
