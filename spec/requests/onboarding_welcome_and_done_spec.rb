require "rails_helper"

RSpec.describe "Onboarding welcome and done screens", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:series) { create(:event_series, name: "Sunbeam", registration_note: "Bring a laptop!") }
  let(:event) { create(:event, name: "Sunbeam Springfield", event_series: series, travel_enabled: false, accommodation_enabled: false) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user, email: user.email, preferred_name: "Robin", date_of_birth: 18.years.ago - 1.month) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 0)
  end

  before { sign_in user }

  describe "welcome" do
    it "greets a new registrant before the first step" do
      get onboarding_path(event_id: event.id)
      expect(response).to redirect_to(onboarding_welcome_path(event_id: event.id))

      get onboarding_welcome_path(event_id: event.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Hey Robin!")
      expect(response.body).to include("This should take about 5 minutes.")
      expect(response.body).to include("Add someone we can reach in an emergency.")
      expect(response.body).to include("Bring a laptop!")
    end

    it "only shows once" do
      post onboarding_start_path(event_id: event.id)

      expect(response).to redirect_to(onboarding_step_path(step: "profile", event_id: event.id))
      expect(participant_event.reload.onboarding_intro_seen_at).to be_present

      get onboarding_path(event_id: event.id)
      expect(response).to redirect_to(onboarding_step_path(step: "profile", event_id: event.id))
    end

    it "skips registrants who are already past the first step" do
      participant_event.update!(onboarding_step: 1)

      get onboarding_path(event_id: event.id)

      expect(response).to redirect_to(onboarding_step_path(step: "health", event_id: event.id))
    end

    it "greets registrants for events outside any series too, without a note" do
      event.update!(event_series: nil)

      get onboarding_path(event_id: event.id)
      expect(response).to redirect_to(onboarding_welcome_path(event_id: event.id))

      get onboarding_welcome_path(event_id: event.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Hey Robin!")
      expect(response.body).not_to include("Bring a laptop!")
    end
  end

  describe "submitting" do
    before do
      participant_event.update!(onboarding_step: 99)
      participant_event.emergency_contacts.create!(name: "Erin", phone: "+14155550100")
    end

    def submit
      post complete_onboarding_path(event_id: event.id), params: {
        code_of_conduct_accepted: "1", code_of_conduct_signature: "Robin Participant"
      }
    end

    it "lands registrants on the done screen" do
      create(:consent, :signed, participant_event: participant_event)

      submit

      expect(response).to redirect_to(onboarding_done_path(event_id: event.id))
    end

    it "does the same for events outside any series" do
      event.update!(event_series: nil)
      create(:consent, :signed, participant_event: participant_event)

      submit

      expect(response).to redirect_to(onboarding_done_path(event_id: event.id))
    end
  end

  describe "done" do
    it "is only reachable after submitting" do
      get onboarding_done_path(event_id: event.id)

      expect(response).to redirect_to(onboarding_path(event_id: event.id))
    end

    it "waits for a minor's submission to go through, not just the code of conduct" do
      participant.update!(date_of_birth: 15.years.ago)
      participant_event.update!(code_of_conduct_accepted_at: Time.current)

      get onboarding_done_path(event_id: event.id)

      expect(response).to redirect_to(onboarding_path(event_id: event.id))
    end

    it "waits for an adult's emergency contact, not just the code of conduct" do
      participant_event.update!(code_of_conduct_accepted_at: Time.current)

      get onboarding_done_path(event_id: event.id)

      expect(response).to redirect_to(onboarding_path(event_id: event.id))
    end

    it "sends rejected registrations to the dashboard" do
      participant_event.update!(status: :rejected, code_of_conduct_accepted_at: Time.current)
      participant_event.emergency_contacts.create!(name: "Erin", phone: "+14155550100")

      get onboarding_done_path(event_id: event.id)

      expect(response).to redirect_to(dashboard_path)
    end

    it "doesn't ask for the waiver again right after it was signed" do
      participant_event.update!(code_of_conduct_accepted_at: Time.current, onboarding_step: 99)
      participant_event.emergency_contacts.create!(name: "Erin", phone: "+14155550100")
      consent = create(:consent, participant_event: participant_event, status: :sent,
        docuseal_envelope_id: "sub-1", docuseal_participant_slug: "abc123")
      client = instance_double(Docuseal::Client)
      allow(Docuseal::Client).to receive(:for).and_return(client)
      allow(client).to receive(:get_submission).and_return(
        "submitters" => [ { "slug" => "abc123", "completed_at" => Time.current.iso8601 } ]
      )

      post onboarding_waiver_complete_path(event_id: event.id)

      expect(response).to redirect_to(onboarding_done_path(event_id: event.id))
      expect(consent.reload).to be_participant_portion_signed
      follow_redirect!
      expect(response.body).not_to include("Sign the event waiver")
    end

    it "shows the entry ticket once the registration is confirmed" do
      participant_event.update!(status: :complete, code_of_conduct_accepted_at: Time.current)
      participant_event.emergency_contacts.create!(name: "Erin", phone: "+14155550100")
      create(:consent, :signed, participant_event: participant_event)

      get onboarding_done_path(event_id: event.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("You're all set!")
      expect(response.body).to include("ENTRY TICKET")
      expect(response.body).to include("Bring a laptop!")
    end

    it "explains what's left for a minor before the guardian finishes, without a ticket" do
      participant.update!(date_of_birth: 15.years.ago)
      participant_event.update!(status: :awaiting_guardian, code_of_conduct_accepted_at: Time.current)
      create(:guardian_participant_event, participant_event: participant_event)
      create(:consent, :signed, participant_event: participant_event)

      get onboarding_done_path(event_id: event.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("You're registered!")
      completion = RegistrationCompletionPresenter.new(participant_event.reload, viewer: :participant)
      expect(completion).not_to be_confirmed
      expect(response.body).to include(completion.headline)
      expect(response.body).not_to include("ENTRY TICKET")
    end
  end
end
