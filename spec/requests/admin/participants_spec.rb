require "rails_helper"

RSpec.describe "Admin::Participants", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, accommodation_enabled: false) }
  let(:global_admin) { User.create!(email: "ga-participants@example.com", name: "Global Admin", global_role: "global_admin") }

  def complete_onboarding!(pe)
    pe.travels.create!(direction: "inbound", mode: "car")
    pe.travels.create!(direction: "outbound", mode: "car")
    pe.create_medical!
    pe.create_dietary!
    pe.create_accessibility!
    pe.create_safeguarding_info!
    create(:consent, participant_event: pe)
  end

  describe "GET index with flag=incomplete_onboarding" do
    before { sign_in global_admin }

    it "lists only participants with incomplete onboarding" do
      complete_pe = create(:participant_event, event: event,
        participant: create(:participant, legal_first_name: "Complete", legal_last_name: "Person"))
      complete_onboarding!(complete_pe)
      incomplete_pe = create(:participant_event, event: event,
        participant: create(:participant, legal_first_name: "Incomplete", legal_last_name: "Person"))

      get admin_event_participants_path(event.slug), params: { flag: "incomplete_onboarding" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(incomplete_pe.participant.full_name)
      expect(response.body).not_to include(complete_pe.participant.full_name)
    end

    it "combines with the checked_in filter without raising" do
      create(:participant_event, event: event)

      get admin_event_participants_path(event.slug),
        params: { flag: "incomplete_onboarding", checked_in: "yes" }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "accommodation when disabled for the event" do
    let(:participant_event) { create(:participant_event, event: event) }

    before { sign_in global_admin }

    it "hides the Accommodation tab on the participant page" do
      get admin_event_participant_path(event, participant_event)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(accommodation_admin_event_participant_path(event, participant_event))
    end

    it "redirects direct visits to the accommodation page" do
      get accommodation_admin_event_participant_path(event, participant_event)

      expect(response).to redirect_to(admin_event_participant_path(event, participant_event))
      expect(flash[:alert]).to include("Accommodation is disabled")
    end

    it "shows the tab and page when accommodation is enabled" do
      event.update!(accommodation_enabled: true)

      get admin_event_participant_path(event, participant_event)
      expect(response.body).to include(accommodation_admin_event_participant_path(event, participant_event))

      get accommodation_admin_event_participant_path(event, participant_event)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST sync_slack_channel" do
    include ActiveJob::TestHelper

    before { sign_in global_admin }

    it "enqueues the sync job instead of calling Slack in-request" do
      event.update!(slack_channel_id: "C123")

      expect {
        post sync_slack_channel_admin_event_participants_path(event.slug), params: { send_emails: "1" }
      }.to have_enqueued_job(SyncSlackChannelJob).with(event.id, send_emails: true)

      expect(response).to redirect_to(admin_event_participants_path(event.slug))
    end

    it "rejects events without a configured Slack channel" do
      expect {
        post sync_slack_channel_admin_event_participants_path(event.slug)
      }.not_to have_enqueued_job(SyncSlackChannelJob)

      expect(flash[:alert]).to include("No Slack channel")
    end
  end

  describe "GET consents" do
    let(:participant_event) { create(:participant_event, event: event) }

    before { sign_in global_admin }

    def get_consents
      get consents_admin_event_participant_path(event, participant_event)
    end

    it "lists an applicable custom document even when no consent row exists yet" do
      create(:custom_document, :physical, :minors_only, event: event, name: "Entry Authorization")

      get_consents

      expect(response.body).to include("Additional Documents")
      expect(response.body).to include("Entry Authorization")
      expect(response.body).to include("Awaiting participant upload")
    end

    it "shows an uploaded physical document as awaiting guardian confirmation" do
      doc = create(:custom_document, :physical, :dual_signer, event: event, name: "Entry Authorization")
      create(:guardian_participant_event, participant_event: participant_event)
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, participant_signed_at: Time.current)
      consent.physical_uploads.attach(io: StringIO.new("bytes"), filename: "signed.jpg", content_type: "image/jpeg")

      get_consents

      expect(response.body).to include("Awaiting guardian confirmation")
      expect(response.body).to include("View Upload")
    end

    it "shows an untouched DocuSeal document as not started" do
      create(:custom_document, event: event, name: "Hotel Waiver")

      get_consents

      expect(response.body).to include("Hotel Waiver")
      expect(response.body).to include("Not started")
    end

    it "does not duplicate a custom document consent in the main consents table" do
      doc = create(:custom_document, event: event, name: "Hotel Waiver")
      create(:consent, :signed, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc)

      get_consents

      expect(response.body.scan("Hotel Waiver").count).to eq(1)
    end

    it "keeps consents for archived documents in the main consents table" do
      doc = create(:custom_document, :archived, event: event, name: "Old Form")
      create(:consent, :signed, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc)

      get_consents

      expect(response.body).to include("Old Form")
    end
  end
end
