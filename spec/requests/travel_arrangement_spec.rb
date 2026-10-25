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
