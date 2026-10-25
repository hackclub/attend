require "rails_helper"

RSpec.describe "Onboarding travel autosave", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, accommodation_enabled: false) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 1)
  end

  before { sign_in user }

  def autosave(inbound:, outbound: { mode: "other", other_details: "Collecting details" })
    patch onboarding_step_path(step: "travel", event_id: event.id), params: {
      autosave: "true",
      travel_inbound: inbound,
      travel_outbound: outbound
    }
  end

  it "reports a new flight leg as awaiting explicit save without creating duplicates" do
    inbound = {
      mode: "plane",
      travel_legs_attributes: {
        "0" => {
          position: "0",
          flight_code: "BA123",
          departure_airport: "LHR",
          arrival_airport: "VIE",
          departure_time: "2026-10-01T09:00",
          arrival_time: "2026-10-01T12:00"
        }
      }
    }

    2.times { autosave(inbound: inbound) }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "success" => true,
      "pending" => [ "new_flight_legs" ]
    )
    expect(participant_event.travels.inbound.first.reload.travel_legs).to be_empty
  end

  it "rolls back scalar travel changes when an existing flight leg is invalid" do
    inbound = participant_event.travels.create!(direction: "inbound", mode: "plane", notes: "Original")
    leg = inbound.travel_legs.create!(
      position: 0,
      flight_code: "BA123",
      departure_airport: "LHR",
      arrival_airport: "VIE",
      departure_time: Time.zone.parse("2026-10-01 09:00"),
      arrival_time: Time.zone.parse("2026-10-01 12:00")
    )

    autosave(inbound: {
      mode: "plane",
      notes: "Unsaved",
      travel_legs_attributes: {
        "0" => {
          id: leg.id,
          position: "0",
          flight_code: "BA123",
          departure_airport: "INVALID",
          arrival_airport: "VIE",
          departure_time: "2026-10-01T09:00",
          arrival_time: "2026-10-01T12:00"
        }
      }
    })

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["errors"])
      .to include(a_string_including("Arrival flight leg 1", "Departure airport"))
    expect(inbound.reload.notes).to eq("Original")
    expect(leg.reload.departure_airport).to eq("LHR")
  end
end
