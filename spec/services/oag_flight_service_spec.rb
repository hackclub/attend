require "rails_helper"

RSpec.describe OagFlightService do
  def instance(dep_iata, arr_iata, key)
    {
      "departure" => { "airport" => { "iata" => dep_iata } },
      "arrival" => { "airport" => { "iata" => arr_iata } },
      "scheduleInstanceKey" => key
    }
  end

  # AA2365 shape: one-stop PHL -> BTV -> PHL. OAG returns the through-flight
  # (PHL->PHL, whose times are the origin's) alongside each segment.
  let(:through_flight) { instance("PHL", "PHL", "through") }
  let(:first_segment)  { instance("PHL", "BTV", "seg1") }
  let(:second_segment) { instance("BTV", "PHL", "seg2") }
  let(:flights) { [ through_flight, first_segment, second_segment ] }

  describe ".find_by_route" do
    it "prefers the instance matching both endpoints over the through-flight" do
      expect(described_class.find_by_route(flights, "BTV", "PHL")).to eq(second_segment)
    end

    it "falls back to the first destination match when the origin matches nothing" do
      expect(described_class.find_by_route(flights, "XXX", "PHL")).to eq(through_flight)
    end

    it "matches destination-only when no origin is given" do
      expect(described_class.find_by_route(flights, nil, "BTV")).to eq(first_segment)
    end

    it "returns nil when nothing matches the destination" do
      expect(described_class.find_by_route(flights, "BTV", "SFO")).to be_nil
    end

    it "matches ICAO codes too" do
      flights = [ instance(nil, nil, "icao").deep_merge(
        "departure" => { "airport" => { "icao" => "KBTV" } },
        "arrival" => { "airport" => { "icao" => "KPHL" } }
      ) ]
      expect(described_class.find_by_route(flights, "KBTV", "KPHL")).to eq(flights.first)
    end
  end

  describe ".find_by_destination" do
    it "keeps the old destination-only behavior" do
      expect(described_class.find_by_destination(flights, "PHL")).to eq(through_flight)
    end
  end
end
