require "rails_helper"

RSpec.describe "Onboarding review step", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user) }

  before do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 99, onboarding_intro_seen_at: Time.current)
    sign_in user
  end

  context "when the event has accommodation" do
    let(:event) { create(:event, accommodation_enabled: true) }

    it "shows the accommodation section with a link to its step" do
      get onboarding_step_path(step: "review", event_id: event.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Roommate Preferences")
      expect(response.body).to include(onboarding_step_path(step: "accommodation", event_id: event.id))
    end
  end

  # The accommodation step isn't in the wizard, so its Edit link would only
  # bounce off "Invalid step."
  context "when the event has no accommodation" do
    let(:event) { create(:event, accommodation_enabled: false) }

    it "leaves the accommodation section out" do
      get onboarding_step_path(step: "review", event_id: event.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Roommate Preferences")
      expect(response.body).not_to include(onboarding_step_path(step: "accommodation", event_id: event.id))
    end
  end
end
