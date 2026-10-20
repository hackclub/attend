require "rails_helper"

RSpec.describe "Onboarding Haven skin", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:haven) { create(:event_series, name: "Haven", haven_onboarding: "1") }
  let(:event) { create(:event, name: "Haven Boston", event_series: haven, venue_name: "Boston Public Library", location_city: "Boston") }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user) }

  before do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 0)
    sign_in user
  end

  it "renders onboarding in the Haven skin, forcing the light theme" do
    cookies[:attend_theme] = "dracula"

    get onboarding_step_path(step: "profile", event_id: event.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-theme="light" data-brand="haven"')
    expect(response.body).to include("haven-bottom-strip")
    expect(response.body).to include("You&#39;re registering for")
    expect(response.body).to include("Boston Public Library, Boston")
    expect(response.body).to include("so we can ship prizes to attendees in the US")
  end

  it "adds the laptop reminder to the review step" do
    participant.participant_events.find_by!(event: event).update!(onboarding_step: 99)

    get onboarding_step_path(step: "review", event_id: event.id)

    expect(response.body).to include("Bring a laptop!")
  end

  context "when the series hasn't switched Haven onboarding on" do
    let(:haven) { create(:event_series, name: "Not Haven") }

    it "keeps the stock look and the user's theme" do
      cookies[:attend_theme] = "dracula"

      get onboarding_step_path(step: "profile", event_id: event.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-theme="dracula"')
      expect(response.body).not_to include("data-brand")
      expect(response.body).not_to include("haven-bottom-strip")
      expect(response.body).not_to include("ship prizes")
    end
  end
end

RSpec.describe "Onboarding invitation entry in the Haven skin", type: :request do
  let(:haven) { create(:event_series, name: "Haven", haven_onboarding: "1") }
  let(:event) { create(:event, name: "Haven Boston", event_series: haven) }
  let(:invitation) { create(:invitation, event: event, email: "invited@example.com", sent_at: Time.current) }

  it "brands the signed-out invitation page" do
    get onboarding_path(invite: invitation.token)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-brand="haven"')
    expect(response.body).to include("You&#39;re invited to")
    expect(response.body).to include("Register for Haven Boston")
  end

  it "leaves invitations for other events unbranded" do
    event.update!(event_series: nil)

    get onboarding_path(invite: invitation.token)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("data-brand")
  end
end
