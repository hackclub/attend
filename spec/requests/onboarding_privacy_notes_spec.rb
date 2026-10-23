require "rails_helper"

# A series can leave the privacy notes off its accommodation and health steps.
RSpec.describe "Onboarding privacy notes", type: :request do
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

  it "explains who sees health answers by default" do
    get onboarding_step_path(step: "health", event_id: event.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Other attendees cannot.")
    expect(response.body).to include("These answers are used to plan safety")
    expect(response.body).to include("send a private request to event staff")
  end

  context "when the series hides the notes" do
    before { series.update!(hide_privacy_notes: true) }

    it "leaves the rooming note and private request link out" do
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

    it "leaves the health privacy notes and private request links out" do
      get onboarding_step_path(step: "health", event_id: event.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Choose “Nothing to add” when a section does not apply, or add details.")
      expect(response.body).not_to include("Other attendees cannot.")
      expect(response.body).not_to include("These answers are used to plan safety")
      expect(response.body).not_to include("send a private request to event staff")
    end

    it "drops the option to discuss a section privately" do
      get onboarding_step_path(step: "health", event_id: event.id)

      expect(response.body).not_to include("ask to discuss a section privately")
      expect(response.body).not_to include('value="private"')
      expect(response.body.scan('value="details"').size).to eq(3)
    end

    it "keeps the option on a section already answered privately" do
      Medical.create!(participant_event: participant_event, section_response: "private")

      get onboarding_step_path(step: "health", event_id: event.id)

      expect(response.body.scan('value="private"').size).to eq(1)
    end
  end
end
