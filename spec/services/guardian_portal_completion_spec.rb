require "rails_helper"

RSpec.describe GuardianPortalCompletion do
  let(:event) { create(:event, freedom_waivers_enabled: true) }
  let(:participant_event) do
    create(:participant_event, participant: create(:participant, date_of_birth: 15.years.ago), event: event,
      status: :awaiting_guardian, code_of_conduct_accepted_at: Time.current)
  end
  let(:gpe) { create(:guardian_participant_event, participant_event: participant_event, status: :in_progress) }

  describe "#complete!" do
    before do
      gpe.emergency_contacts.create!(name: "Pat Guardian", phone: "+14155550150", relationship: "Parent")
      create(:consent, :signed, participant_event: participant_event, guardian_signed_at: Time.current)
      create(:consent, :signed, :freedom_waiver, participant_event: participant_event)
    end

    # The waiver and freedom waiver webhooks can land together; each loaded
    # the link before the other completed it.
    it "does nothing for a copy loaded before another request completed the link" do
      stale_copy = GuardianParticipantEvent.find(gpe.id)
      gpe.update!(status: :completed, completed_at: 1.hour.ago)

      expect(described_class.new(stale_copy).complete!).to be(false)
      expect(gpe.reload.completed_at).to be_within(1.second).of(1.hour.ago)
    end

    it "sends guardian-only documents that don't have a submission yet" do
      sent_doc = create(:custom_document, :guardian_only, event: event)
      create(:consent, :custom_document, participant_event: participant_event, custom_document: sent_doc,
        status: :sent, docuseal_envelope_id: "custom-1")
      new_doc = create(:custom_document, :guardian_only, event: event)

      expect(described_class.new(gpe).complete!).to be(true)

      new_consent = participant_event.consents.find_by!(custom_document: new_doc)
      expect(DocusealJobs::CreateCustomDocumentJob).to have_been_enqueued.with(new_consent.id).exactly(:once)
      expect(DocusealJobs::CreateCustomDocumentJob).to have_been_enqueued.exactly(:once)
    end
  end

  # Moved here from GuardianPortalController so automatic completion can
  # trigger documents too. No spec reached these branches before the move.
  describe "#ensure_waiver_exists_and_triggered" do
    it "resets failed waivers and sends them again" do
      waiver = create(:consent, participant_event: participant_event, status: :failed, failure_reason: "DocuSeal error")
      freedom_waiver = create(:consent, :freedom_waiver, participant_event: participant_event, status: :failed,
        failure_reason: "DocuSeal error")

      described_class.new(gpe).ensure_waiver_exists_and_triggered

      expect(waiver.reload).to be_pending
      expect(freedom_waiver.reload).to be_pending
      expect(DocusealJobs::CreateMinorWaiverJob).to have_been_enqueued.with(waiver.id).at_least(:once)
      expect(DocusealJobs::CreateFreedomWaiverJob).to have_been_enqueued.with(freedom_waiver.id).at_least(:once)
    end
  end
end
