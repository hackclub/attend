require "rails_helper"

RSpec.describe TravelLegDateMerging do
  # Minimal host that exposes the private concern methods for testing.
  let(:host) do
    Class.new do
      include TravelLegDateMerging
      def normalize(params) = normalize_leg_times!(params)
    end.new
  end

  def leg(attrs) = { travel_legs_attributes: { "0" => attrs } }
  def result(params) = params[:travel_legs_attributes]["0"]

  it "converts wall-clock times to UTC using the explicitly picked timezone" do
    params = leg(
      departure_airport: "JFK",
      arrival_airport: "LHR",
      departure_time: "2026-07-15T23:00",
      arrival_time: "2026-07-16T11:00",
      departure_time_zone: "America/New_York",
      arrival_time_zone: "Europe/London"
    )

    host.normalize(params)

    # 23:00 EDT (-04:00) -> 03:00Z next day
    expect(result(params)[:departure_time]).to eq("2026-07-16T03:00:00Z")
    # 11:00 BST (+01:00) -> 10:00Z
    expect(result(params)[:arrival_time]).to eq("2026-07-16T10:00:00Z")
  end

  it "strips the *_time_zone params (they aren't columns)" do
    params = leg(
      departure_time: "2026-07-15T12:00",
      arrival_time: "2026-07-15T14:00",
      departure_time_zone: "Europe/Vienna",
      arrival_time_zone: "Europe/Vienna"
    )

    host.normalize(params)

    expect(result(params)).not_to have_key(:departure_time_zone)
    expect(result(params)).not_to have_key(:arrival_time_zone)
  end

  it "falls back to the airport's timezone when no zone is picked" do
    allow(FlightTrackingService).to receive(:airport_timezone).with("JFK").and_return("America/New_York")
    allow(FlightTrackingService).to receive(:airport_timezone).with("LHR").and_return("Europe/London")

    params = leg(
      departure_airport: "JFK",
      arrival_airport: "LHR",
      departure_time: "2026-07-15T23:00",
      arrival_time: "2026-07-16T11:00",
      departure_time_zone: "",
      arrival_time_zone: ""
    )

    host.normalize(params)

    expect(result(params)[:departure_time]).to eq("2026-07-16T03:00:00Z")
    expect(result(params)[:arrival_time]).to eq("2026-07-16T10:00:00Z")
  end

  it "falls back to the app timezone when neither a pick nor an airport zone is available" do
    allow(FlightTrackingService).to receive(:airport_timezone).and_return(nil)

    params = leg(departure_time: "2026-07-15T12:00", departure_time_zone: "")

    Time.use_zone("UTC") { host.normalize(params) }

    expect(result(params)[:departure_time]).to eq("2026-07-15T12:00:00Z")
  end

  it "leaves a blank time untouched" do
    params = leg(departure_time: "", departure_time_zone: "Europe/Vienna")

    host.normalize(params)

    expect(result(params)[:departure_time]).to eq("")
  end

  it "is a no-op when there are no leg attributes" do
    params = { mode: "plane" }
    expect { host.normalize(params) }.not_to raise_error
  end
end
