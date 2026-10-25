require 'rails_helper'

RSpec.describe TravelLeg, type: :model do
  describe "travel pickup" do
    it "records and clears travel pickup on a flight leg" do
      user = create(:user)
      leg = create(
        :travel_leg,
        travel: Travel.create!(
          participant_event: create(:participant_event),
          direction: "inbound",
          mode: "plane"
        ),
        departure_airport: "JFK",
        arrival_airport: "LHR"
      )

      leg.mark_travel_picked_up!(user)
      expect(leg.reload.travel_picked_up_at).to be_present
      expect(leg.picked_up_by).to eq(user)
      expect(leg).to be_travel_picked_up

      leg.unmark_travel_picked_up!
      expect(leg.reload.travel_picked_up_at).to be_nil
      expect(leg.picked_up_by).to be_nil
      expect(leg).not_to be_travel_picked_up
    end
  end

  describe "time zones" do
    let(:travel) { Travel.create!(participant_event: create(:participant_event), direction: "inbound", mode: "plane") }

    def build_leg(**attrs)
      travel.travel_legs.build(
        position: 0, flight_code: "BA112", departure_airport: "JFK", arrival_airport: "LHR",
        departure_time: Time.utc(2026, 6, 6, 1, 0), arrival_time: Time.utc(2026, 6, 6, 8, 30), **attrs
      )
    end

    it "reads times back in the stored zone" do
      leg = build_leg(departure_time_zone: "Eastern Time (US & Canada)")

      expect(leg.local_departure_time.strftime("%Y-%m-%d %H:%M %Z")).to eq("2026-06-05 21:00 EDT")
    end

    it "falls back to the airport's zone, then UTC, when no zone is stored" do
      expect(build_leg.local_arrival_time.strftime("%H:%M %Z")).to eq("09:30 BST")
      expect(build_leg(arrival_airport: "ZZZ").local_arrival_time.strftime("%H:%M %Z")).to eq("08:30 UTC")
    end

    it "pre-selects Auto when the stored zone is the airport's own" do
      leg = build_leg(departure_time_zone: "America/New_York", arrival_time_zone: "Europe/Vienna")

      expect(leg.time_zone_pick(:departure)).to eq("")
      expect(leg.time_zone_pick(:arrival)).to eq("Europe/Vienna")
    end

    it "requires a zone only for times typed as local wall-clock times" do
      expect(build_leg(departure_airport: "ZZZ")).to be_valid

      leg = build_leg(departure_airport: "ZZZ", entered_as_local_time: true, arrival_time_zone: "Europe/London")
      expect(leg).not_to be_valid
      expect(leg.errors[:departure_time_zone]).to be_present
    end

    it "rejects an arrival that isn't after the departure" do
      leg = build_leg(arrival_time: Time.utc(2026, 6, 6, 1, 0))

      expect(leg).not_to be_valid
      expect(leg.errors[:arrival_time]).to include(a_string_including("must be after the departure time"))
    end
  end

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
