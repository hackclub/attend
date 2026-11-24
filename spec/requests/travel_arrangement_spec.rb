require "rails_helper"

RSpec.describe "Travel arrangement state", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, accommodation_enabled: false, travel_enabled: true) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event,
      status: :in_progress, onboarding_step: 1)
  end

  before { sign_in user }

  it "saves independent unresolved answers and advances without invented details" do
    patch onboarding_step_path(step: "travel", event_id: event.id), params: {
      travel_inbound: { arrangement_status: "not_arranged" },
      travel_outbound: { arrangement_status: "provisional", mode: "train" }
    }

    expect(response).to redirect_to(onboarding_step_path(step: "health", event_id: event.id))
    expect(participant_event.reload.travel_inbound).to have_attributes(
      arrangement_status: "not_arranged", mode: nil, arrival_time: nil, departure_time: nil
    )
    expect(participant_event.travel_outbound).to have_attributes(
      arrangement_status: "provisional", mode: "train"
    )
    expect(participant_event.onboarding_progress[:steps].find { |step| step[:name] == "travel" }[:done]).to be(true)
    expect(participant_event).to be_travel_outstanding
  end

  it "rolls both directions back when one confirmed direction is invalid" do
    inbound = participant_event.travels.create!(direction: :inbound, arrangement_status: :provisional,
      mode: :train, notes: "original")
    participant_event.travels.create!(direction: :outbound, arrangement_status: :provisional, mode: :train)

    patch dashboard_event_travel_path(participant_event), params: {
      travel_inbound: {
        arrangement_status: "confirmed", mode: "other", other_details: "Walking", notes: "changed"
      },
      travel_outbound: { arrangement_status: "confirmed", mode: "train" }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(inbound.reload).to have_attributes(arrangement_status: "provisional", notes: "original")
  end

  it "explains why the save failed instead of silently re-rendering" do
    participant_event.travels.create!(direction: :inbound, arrangement_status: :provisional, mode: :train)
    participant_event.travels.create!(direction: :outbound, arrangement_status: :provisional, mode: :train)

    patch dashboard_event_travel_path(participant_event), params: {
      travel_inbound: { arrangement_status: "confirmed", mode: "train" },
      travel_outbound: { arrangement_status: "provisional", mode: "train" }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("We couldn't save your travel yet")
    expect(response.body).to include("Arrival: Train departure station can&#39;t be blank")
  end

  it "confirms flights through regional airports with the time zone left on auto" do
    participant_event.travels.create!(direction: :inbound, arrangement_status: :provisional, mode: :plane)
    participant_event.travels.create!(direction: :outbound, arrangement_status: :provisional, mode: :plane)

    leg = ->(from, to, departs, arrives) {
      { "0" => { id: "", position: "0", flight_code: "EI 123", departure_airport: from, arrival_airport: to,
                 departure_time: departs, departure_time_zone: "", arrival_time: arrives, arrival_time_zone: "" } }
    }
    patch dashboard_event_travel_path(participant_event), params: {
      travel_inbound: { arrangement_status: "confirmed", mode: "plane",
                        travel_legs_attributes: leg.call("LHR", "SNN", "2026-12-04T18:05", "2026-12-04T19:25") },
      travel_outbound: { arrangement_status: "confirmed", mode: "plane",
                         travel_legs_attributes: leg.call("SNN", "LHR", "2026-12-06T20:05", "2026-12-06T21:25") }
    }

    expect(response).to redirect_to(dashboard_event_path(participant_event))
    inbound_leg = participant_event.reload.travel_inbound.travel_legs.sole
    expect(inbound_leg).to have_attributes(departure_time_zone: "Europe/London", arrival_time_zone: "Europe/Dublin")
    expect(participant_event.travel_outbound).to be_confirmed
  end

  it "reads every airport code in the time zone table as a string" do
    OagFlightService::AirportTimezones.reset!
    data = OagFlightService::AirportTimezones.data

    expect(data.keys).to all(be_a(String).and(match(/\A[A-Z0-9]{3,4}\z/)))
    # Bare YAML keys like OFF/YES parse as booleans.
    expect(FlightTrackingService.airport_timezone("OFF")).to eq("America/Chicago")
    expect(FlightTrackingService.airport_timezone("YES")).to eq("Asia/Tehran")
  end

  it "preserves confirmed details while a direction is marked not arranged" do
    inbound = participant_event.travels.create!(direction: :inbound, arrangement_status: :confirmed,
      mode: :other, other_details: "Private coach")
    participant_event.travels.create!(direction: :outbound, arrangement_status: :provisional, mode: :car)

    patch dashboard_event_travel_path(participant_event), params: {
      travel_inbound: { arrangement_status: "not_arranged" },
      travel_outbound: { arrangement_status: "provisional", mode: "car" }
    }

    expect(response).to redirect_to(dashboard_event_path(participant_event))
    expect(inbound.reload).to have_attributes(
      arrangement_status: "not_arranged", mode: "other", other_details: "Private coach"
    )
  end

  it "shows unresolved directions and no invented deadline on the dashboard" do
    participant_event.travels.create!(direction: :inbound, arrangement_status: :not_arranged)
    participant_event.travels.create!(direction: :outbound, arrangement_status: :provisional, mode: :train)

    get dashboard_event_path(participant_event)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Arrival travel has not been arranged")
    expect(response.body).to include("Departure travel is provisional")
    expect(response.body).to include("No travel update deadline has been set")
    expect(response.body).to include("Update travel")
  end

  it "renders blank times without synthetic midnight values" do
    participant_event.travels.create!(direction: :inbound, arrangement_status: :confirmed,
      mode: :train, train_departure_station: "Home", train_arrival_station: "Event",
      arrival_time: 1.week.from_now)
    participant_event.travels.create!(direction: :outbound, arrangement_status: :provisional, mode: :bus)

    get dashboard_event_travel_edit_path(participant_event)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("T00:00")
  end
end
