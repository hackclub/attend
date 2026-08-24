require "rails_helper"

RSpec.describe "Api::V1::TravelCalendar", type: :request do
  let(:event) { create(:event, timezone: "America/Los_Angeles") }

  before do
    event.generate_api_key!
  end

  def auth_headers
    { "Authorization" => "Bearer #{event.api_key}" }
  end

  it "returns inbound and outbound entries in the canonical event-local shape" do
    inbound_registration = create(:participant_event, event: event, status: :complete)
    outbound_registration = create(:participant_event, event: event, status: :complete)
    inbound = Travel.create!(
      participant_event: inbound_registration,
      direction: "inbound",
      mode: "train",
      arrival_time: Time.utc(2026, 8, 24, 16, 30),
      train_departure_station: "Sacramento",
      train_arrival_station: "Oakland",
      carrier: "Amtrak"
    )
    outbound = Travel.create!(
      participant_event: outbound_registration,
      direction: "outbound",
      mode: "bus",
      departure_time: Time.utc(2026, 8, 25, 17, 45),
      bus_departure_location: "Oakland",
      bus_arrival_location: "San Jose",
      carrier: "Greyhound"
    )

    get "/api/v1/events/#{event.id}/travel", headers: auth_headers

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json).to include(
      "eventTimezone" => "America/Los_Angeles",
      "dates" => [ "2026-08-24", "2026-08-25" ],
      "counts" => a_hash_including("total" => 2, "inbound" => 1, "outbound" => 1)
    )

    entries = json.fetch("entries").index_by { |entry| entry.fetch("id") }
    expect(entries.fetch(inbound.id)).to include(
      "direction" => "inbound",
      "mode" => "train",
      "primaryTimeAt" => "2026-08-24T09:30:00-07:00",
      "agendaDate" => "2026-08-24",
      "route" => "Sacramento → Oakland",
      "reference" => "Amtrak",
      "pickupState" => "awaiting_pickup"
    )
    expect(entries.fetch(outbound.id)).to include(
      "direction" => "outbound",
      "mode" => "bus",
      "agendaDate" => "2026-08-25",
      "route" => "Oakland → San Jose",
      "reference" => "Greyhound",
      "pickupState" => nil
    )
  end

  it "returns the same entry IDs from the legacy API URL" do
    participant_event = create(:participant_event, event: event, status: :complete)
    Travel.create!(
      participant_event: participant_event,
      direction: "inbound",
      mode: "car",
      expected_arrival_time: Time.utc(2026, 8, 24, 18),
      origin_address: "123 Main Street"
    )

    get "/api/v1/events/#{event.id}/travel", headers: auth_headers
    canonical_ids = JSON.parse(response.body).fetch("entries").pluck("id")

    get "/api/v1/events/#{event.id}/airport_mode", headers: auth_headers
    legacy_json = JSON.parse(response.body)

    expect(response).to have_http_status(:ok)
    expect(legacy_json.fetch("entries").pluck("id")).to eq(canonical_ids)
  end
end
