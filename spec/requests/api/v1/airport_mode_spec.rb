require "rails_helper"

RSpec.describe "Api::V1::AirportMode", type: :request do
  let(:event) { create(:event, timezone: "America/Los_Angeles") }
  let(:participant_event) { create(:participant_event, event: event, status: :complete) }

  before do
    event.generate_api_key!
  end

  it "serves the canonical travel calendar JSON from the legacy URL" do
    travel = Travel.create!(
      participant_event: participant_event,
      direction: "inbound",
      mode: "plane"
    )
    create(
      :travel_leg,
      travel: travel,
      flight_code: "UA123",
      departure_airport: "JFK",
      arrival_airport: "SFO",
      departure_time: Time.utc(2026, 7, 15, 15, 30),
      arrival_time: Time.utc(2026, 7, 15, 20, 30)
    )

    get "/api/v1/events/#{event.id}/airport_mode",
      headers: { "Authorization" => "Bearer #{event.api_key}" }

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json.fetch("entries").sole).to include(
      "id" => travel.id,
      "primaryTimeAt" => "2026-07-15T13:30:00-07:00",
      "agendaDate" => "2026-07-15",
      "mode" => "plane",
      "route" => "JFK → SFO",
      "pickupState" => "awaiting_pickup"
    )
  end
end
