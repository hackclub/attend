require "rails_helper"

# A series can leave the rooming privacy note off its accommodation step.
RSpec.describe "Onboarding accommodation rooming note", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:series) { create(:event_series, name: "Sunbeam") }
  let(:event) { create(:event, event_series: series, accommodation_enabled: true) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress,
      onboarding_step: 99, onboarding_intro_seen_at: Time.current)
  end

  before { sign_in user }

  it "explains who sees rooming details by default" do
    get onboarding_step_path(step: "accommodation", event_id: event.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Who sees this?")
    expect(response.body).to include("send a private request to event staff")
  end

  context "when the series hides the note" do
    before { series.update!(hide_rooming_note: true) }

    it "leaves the note and private request link out" do
      get onboarding_step_path(step: "accommodation", event_id: event.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Who sees this?")
      expect(response.body).not_to include("send a private request to event staff")
      expect(response.body).not_to include("portal-note-info")
    end

    it "still shows the room assignment" do
      Accommodation.create!(participant_event: participant_event, assigned_room: "Room 12")

      get onboarding_step_path(step: "accommodation", event_id: event.id)

      expect(response.body).to include("Your room assignment is recorded as <strong>Room 12</strong>.")
      expect(response.body).not_to include("Who sees this?")
    end
  end
end
