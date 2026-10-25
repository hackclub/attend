require "rails_helper"

# Flight leg times are typed as local airport times, stored as UTC, and must
# read back in the zone they were typed in, on every page that shows them.
RSpec.describe "Flight leg time zones", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, accommodation_enabled: false) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 1)
  end
  let(:inbound) { participant_event.travels.create!(direction: "inbound", mode: "plane") }

  before { sign_in user }

  # A 21:00 EDT departure from JFK, stored as 01:00Z the next day.
  def jfk_leg(**attrs)
    inbound.travel_legs.create!(
      position: 0, flight_code: "BA112",
      departure_airport: "JFK", arrival_airport: "LHR",
      departure_time: Time.utc(2026, 6, 6, 1, 0), departure_time_zone: "America/New_York",
      arrival_time: Time.utc(2026, 6, 6, 8, 30), arrival_time_zone: "Europe/London",
      **attrs
    )
  end

  def autosave_leg(leg, **attrs)
    patch onboarding_step_path(step: "travel", event_id: event.id), params: {
      autosave: "true",
      travel_inbound: {
        mode: "plane",
        travel_legs_attributes: {
          "0" => {
            id: leg.id, position: "0", flight_code: leg.flight_code,
            departure_airport: leg.departure_airport, arrival_airport: leg.arrival_airport,
            departure_time: "2026-06-05T21:00", arrival_time: "2026-06-06T09:30"
          }.merge(attrs)
        }
      },
      travel_outbound: { mode: "other", other_details: "Collecting details" }
    }
  end

  it "shows leg times on the review step in the airport's local time, labelled" do
    jfk_leg
    participant_event.update!(onboarding_step: 99)

    get onboarding_step_path(step: "review", event_id: event.id)

    expect(response.body).to include("Jun 05, 2026 21:00 EDT")
    expect(response.body).to include("Jun 06, 2026 09:30 BST")
    expect(response.body).not_to include("Jun 06, 2026 01:00")
  end

  it "shows leg times on the participant dashboard in local time" do
    jfk_leg

    get dashboard_event_path(participant_event)

    expect(response.body).to include("Jun 05 · 21:00 EDT")
  end

  it "fills the travel form with the local time and re-selects a picked zone" do
    jfk_leg(departure_airport: "ZZZ", departure_time_zone: "Eastern Time (US & Canada)")

    get onboarding_step_path(step: "travel", event_id: event.id)

    page = Nokogiri::HTML(response.body)
    expect(page.at('input[name="travel_inbound[travel_legs_attributes][0][departure_time]"]')["value"])
      .to eq("2026-06-05T21:00")
    expect(page.at('select[name="travel_inbound[travel_legs_attributes][0][departure_time_zone]"] option[selected]')["value"])
      .to eq("Eastern Time (US & Canada)")
    # The arrival zone is just LHR's, so the picker stays on Auto.
    expect(page.at('select[name="travel_inbound[travel_legs_attributes][0][arrival_time_zone]"] option[selected]')["value"])
      .to eq("")
  end

  it "asks for a zone instead of assuming UTC when the airport's zone is unknown" do
    leg = jfk_leg

    autosave_leg(leg, departure_airport: "ZZZ")

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["errors"]).to include(a_string_including("Departure time zone is needed"))
    expect(leg.reload.departure_airport).to eq("JFK")
  end

  it "saves the picked zone and reads the time in it" do
    leg = jfk_leg

    autosave_leg(leg, departure_airport: "ZZZ", departure_time_zone: "Eastern Time (US & Canada)")

    expect(response).to have_http_status(:ok)
    leg.reload
    expect(leg.departure_time).to eq(Time.utc(2026, 6, 6, 1, 0))
    expect(leg.departure_time_zone).to eq("Eastern Time (US & Canada)")
  end

  it "rejects an arrival that isn't after the departure" do
    leg = jfk_leg

    autosave_leg(leg, arrival_time: "2026-06-05T20:00", arrival_airport: "JFK")

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["errors"]).to include(a_string_including("Arrival time must be after the departure time"))
  end
end
