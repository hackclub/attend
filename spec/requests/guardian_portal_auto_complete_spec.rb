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
    create(:guardian_participant_event, :details_reviewed, participant_event: participant_event, status: :in_progress,
      accepted_at: Time.current).tap do |g|
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
    it "completes the guardian and the participant once every waiver is signed, without Submit and finish" do
      expect { guardian_signs_everything }
        .to have_enqueued_mail(ParticipantMailer, :registration_confirmed).once

      expect(gpe.reload).to be_completed
      expect(participant_event.reload).to be_complete
    end

    it "does not complete the guardian of a withdrawn registration" do
      participant_event.withdrawn!

      guardian_signs_everything

      expect(gpe.reload).not_to be_completed
      expect(participant_event.reload).to be_withdrawn
    end
  end

  describe "via the portal" do
    before do
      waiver.update!(status: :signed, signed_at: Time.current, guardian_signed_at: Time.current, pending_on: nil)
      freedom_waiver.update!(status: :signed, signed_at: Time.current, guardian_signed_at: Time.current)
    end

    def save_emergency_contact(**params)
      patch guardian_portal_update_step_path(token: token, step: "emergency"), params: {
        emergency_contact: { name: "Sam Guardian", relationship: "Parent", phone: "+14155550151", priority: 1 },
        **params
      }
    end

    it "completes when the guardian saves their last step" do
      gpe.emergency_contacts.destroy_all

      save_emergency_contact

      expect(response).to redirect_to(guardian_portal_confirmed_path(token: token))
      expect(participant_event.reload).to be_complete
    end

    it "moves on to the next step when a save leaves something to do" do
      freedom_waiver.update!(status: :sent, signed_at: nil, guardian_signed_at: nil)

      save_emergency_contact(advance: "1")

      expect(response).to redirect_to(guardian_portal_step_path(token: token, step: "consents"))
      expect(gpe.reload).not_to be_completed
    end

    it "completes when the guardian returns from signing the waiver" do
      post guardian_portal_waiver_complete_path(token: token)

      expect(response).to redirect_to(guardian_portal_confirmed_path(token: token))
      expect(gpe.reload).to be_completed
    end

    it "sends the guardian back to the consents step after signing while something is missing" do
      gpe.emergency_contacts.destroy_all

      post guardian_portal_freedom_waiver_complete_path(token: token)

      expect(response).to redirect_to(guardian_portal_step_path(token: token, step: "consents"))
      expect(gpe.reload).not_to be_completed
    end
  end

  describe "GET /confirmed" do
    it "sends a guardian who hasn't finished to the overview" do
      get guardian_portal_confirmed_path(token: token)

      expect(response).to redirect_to(guardian_portal_path(token: token))
    end
  end
end
