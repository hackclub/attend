require "rails_helper"

RSpec.describe "Guardian invites locked", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event, guardian_invites_locked: true) }
  let(:participant_event) { create(:participant_event, event: event) }
  let(:gpe) { create(:guardian_participant_event, participant_event: participant_event) }
  let(:token) { gpe.generate_invite_token! }

  describe "guardian portal" do
    it "pauses the waiver signing page" do
      get guardian_portal_waiver_path(token: token)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("isn't open yet")
    end

    it "pauses the freedom waiver signing page" do
      get guardian_portal_freedom_waiver_path(token: token)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("isn't open yet")
    end

    it "does not create waiver consents on the consents step" do
      expect {
        get guardian_portal_step_path(token: token, step: "consents")
      }.not_to change(Consent, :count)

      expect(response.body).to include("Waivers aren't open yet")
    end

    it "does not enqueue DocuSeal submissions on the consents step" do
      expect {
        get guardian_portal_step_path(token: token, step: "consents")
      }.not_to have_enqueued_job(DocusealJobs::CreateMinorWaiverJob)
    end

    it "hides the sign link for waivers prepared before the lock" do
      create(:consent, participant_event: participant_event, status: :sent,
        docuseal_envelope_id: "sub-1", docuseal_guardian_slug: "gslug")

      get guardian_portal_step_path(token: token, step: "consents")

      expect(response.body).not_to include(guardian_portal_waiver_path(token: token))
      expect(response.body).to include("Not open for signing yet")
    end

    context "when the event is not locked" do
      let(:event) { create(:event) }

      it "creates and triggers the waiver on the consents step" do
        expect {
          get guardian_portal_step_path(token: token, step: "consents")
        }.to change { participant_event.consents.where(consent_type: :waiver).count }.by(1)
          .and have_enqueued_job(DocusealJobs::CreateMinorWaiverJob)
      end
    end
  end

  describe "participant onboarding waiver page" do
    let(:user) { create(:user) }
    let(:participant) { create(:participant, user: user, email: user.email) }
    let(:participant_event) do
      create(:participant_event, participant: participant, event: event, status: :in_progress)
    end

    before { sign_in user }

    it "pauses waiver signing" do
      participant_event

      get onboarding_waiver_path(event_id: event.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("not able to sign your waiver yet")
    end
  end

  describe "dashboard guardian invite resend" do
    let(:user) { create(:user) }
    let(:participant) do
      create(:participant, user: user, email: user.email, date_of_birth: 16.years.ago)
    end
    let(:participant_event) do
      create(:participant_event, participant: participant, event: event, status: :awaiting_guardian)
    end

    before { sign_in user }

    it "does not email the guardian while locked" do
      gpe

      expect {
        post dashboard_resend_guardian_invite_path(participant_event)
      }.not_to have_enqueued_job(ActionMailer::MailDeliveryJob)

      expect(response).to redirect_to(dashboard_event_path(participant_event))
      expect(flash[:alert]).to include("aren't open for this event yet")
    end
  end

  describe "GuardianMailer.invitation" do
    it "refuses to send while locked" do
      expect {
        GuardianMailer.invitation(guardian_participant_event: gpe).deliver_now
      }.not_to change { ActionMailer::Base.deliveries.count }

      expect(gpe.reload.invite_token_sent_at).to be_nil
    end
  end

  describe "SendPendingGuardianInvitesJob" do
    it "no-ops when the event was re-locked before the job ran" do
      participant_event.update!(status: :awaiting_guardian)
      gpe

      expect {
        expect {
          SendPendingGuardianInvitesJob.perform_now(event.id)
        }.not_to change(Consent, :count)
      }.not_to have_enqueued_job(ActionMailer::MailDeliveryJob)
    end
  end
end
