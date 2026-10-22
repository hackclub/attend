require "rails_helper"

# Guardians used to finish only by pressing "Submit and finish" on the portal
# overview. Those who signed every waiver and left stayed "Awaiting Parent"
# forever (hackclub/attend#165, #166).
RSpec.describe "Guardian portal automatic completion", type: :request do
  let(:webhook_secret) { "test_webhook_secret" }
  let(:headers) { { "X-Webhook-Secret" => webhook_secret, "Content-Type" => "application/json" } }
  let(:event) { create(:event, freedom_waivers_enabled: true) }
  let(:participant) { create(:participant, date_of_birth: 15.years.ago) }
  let(:participant_event) do
    create(:participant_event, participant: participant, event: event,
      status: :awaiting_guardian, code_of_conduct_accepted_at: Time.current)
  end
  let!(:gpe) do
    create(:guardian_participant_event, participant_event: participant_event, status: :in_progress,
      accepted_at: Time.current, relationship: "Parent").tap do |g|
      g.guardian.update!(legal_first_name: "Pat", legal_last_name: "Guardian", phone: "+14155550150")
      g.emergency_contacts.create!(name: "Pat Guardian", phone: "+14155550150", relationship: "Parent")
    end
  end
  let(:token) { gpe.generate_invite_token! }
  let!(:waiver) do
    create(:consent, participant_event: participant_event, consent_type: :waiver, status: :sent,
      docuseal_envelope_id: "waiver-1", participant_signed_at: Time.current, pending_on: "guardian",
      guardian_participant_event: gpe)
  end
  let!(:freedom_waiver) do
    create(:consent, participant_event: participant_event, consent_type: :freedom_waiver, status: :sent,
      docuseal_envelope_id: "freedom-1", guardian_participant_event: gpe)
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DOCUSEAL_WEBHOOK_SECRET").and_return(webhook_secret)
  end

  def deliver(event_type, consent, role: nil)
    data = { "id" => consent.docuseal_envelope_id, "metadata" => { "consent_id" => consent.id.to_s } }
    data["submission_id"] = consent.docuseal_envelope_id if event_type.start_with?("form.")
    data["role"] = role if role
    post docuseal_api_v1_webhooks_path, params: { "event_type" => event_type, "data" => data }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
  end

  def guardian_signs_everything
    deliver("form.completed", waiver, role: "Guardian")
    deliver("submission.completed", waiver)
    deliver("form.completed", freedom_waiver, role: "Guardian")
    deliver("submission.completed", freedom_waiver)
  end

  describe "via DocuSeal webhooks" do
    it "completes the guardian link and the participant once every waiver is signed, without Submit and finish" do
      expect { guardian_signs_everything }
        .to have_enqueued_mail(ParticipantMailer, :registration_confirmed).once

      expect(gpe.reload).to be_completed
      expect(gpe.completed_at).to be_present
      expect(participant_event.reload).to be_complete
    end

    it "does not complete the guardian while a waiver is still unsigned" do
      deliver("form.completed", waiver, role: "Guardian")
      deliver("submission.completed", waiver)

      expect(gpe.reload).not_to be_completed
      expect(participant_event.reload).not_to be_complete
    end

    it "does not complete a guardian who has not filled in their portal steps" do
      gpe.emergency_contacts.destroy_all

      guardian_signs_everything

      expect(gpe.reload).not_to be_completed
      expect(participant_event.reload).not_to be_complete
    end

    it "is idempotent: replayed webhooks send no second confirmation and keep the completion time" do
      guardian_signs_everything
      completed_at = gpe.reload.completed_at

      expect {
        deliver("submission.completed", freedom_waiver)
        deliver("form.completed", waiver, role: "Guardian")
      }.not_to have_enqueued_mail(ParticipantMailer, :registration_confirmed)

      expect(gpe.reload.completed_at).to eq(completed_at)
    end

    it "triggers the guardian-only custom documents, as Submit and finish does" do
      doc = create(:custom_document, :guardian_only, event: event)

      expect { guardian_signs_everything }
        .to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)

      expect(participant_event.consents.find_by(custom_document: doc)).to be_present
    end
  end

  describe "via the portal" do
    before do
      waiver.update!(status: :signed, signed_at: Time.current, guardian_signed_at: Time.current, pending_on: nil)
      freedom_waiver.update!(status: :signed, signed_at: Time.current, guardian_signed_at: Time.current)
    end

    it "completes when the guardian saves their last step" do
      gpe.emergency_contacts.destroy_all

      patch guardian_portal_update_step_path(token: token, step: "emergency"), params: {
        emergency_contact: { name: "Sam Guardian", relationship: "Parent", phone: "+14155550151", priority: 1 }
      }

      expect(response).to redirect_to(guardian_portal_confirmed_path(token: token))
      expect(gpe.reload).to be_completed
      expect(participant_event.reload).to be_complete
    end

    it "completes when the guardian returns from signing" do
      post guardian_portal_freedom_waiver_complete_path(token: token)

      expect(response).to redirect_to(guardian_portal_confirmed_path(token: token))
      expect(gpe.reload).to be_completed
    end

    it "still completes through Submit and finish" do
      expect { post guardian_portal_complete_path(token: token) }
        .to have_enqueued_mail(ParticipantMailer, :registration_confirmed).once

      expect(response).to redirect_to(guardian_portal_confirmed_path(token: token))
      expect(gpe.reload).to be_completed
      expect(participant_event.reload).to be_complete
    end

    it "treats a second Submit and finish as a no-op" do
      post guardian_portal_complete_path(token: token)
      completed_at = gpe.reload.completed_at

      expect { post guardian_portal_complete_path(token: token) }
        .not_to have_enqueued_mail(ParticipantMailer, :registration_confirmed)

      expect(response).to redirect_to(guardian_portal_confirmed_path(token: token))
      expect(gpe.reload.completed_at).to eq(completed_at)
    end

    it "still refuses Submit and finish while steps are missing" do
      gpe.emergency_contacts.destroy_all

      post guardian_portal_complete_path(token: token)

      expect(response).to redirect_to(guardian_portal_path(token: token))
      expect(gpe.reload).not_to be_completed
    end
  end

  describe "GET /confirmed" do
    it "sends a guardian who hasn't finished to the overview" do
      get guardian_portal_confirmed_path(token: token)

      expect(response).to redirect_to(guardian_portal_path(token: token))
    end

    it "shows the confirmation to a completed guardian" do
      gpe.update!(status: :completed, completed_at: Time.current)

      get guardian_portal_confirmed_path(token: token)

      expect(response).to have_http_status(:ok)
    end
  end
end
