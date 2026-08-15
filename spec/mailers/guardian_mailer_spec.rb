require "rails_helper"

RSpec.describe GuardianMailer, type: :mailer do
  describe "#optional_document_added" do
    let(:event) { create(:event, name: "Midnight") }
    let(:participant_event) { create(:participant_event, event: event) }
    let(:guardian_participant_event) do
      create(:guardian_participant_event, participant_event: participant_event,
        status: :completed, completed_at: Time.current)
    end

    before do
      participant_event.participant.update!(legal_first_name: "Robin")
      guardian_participant_event.guardian.update!(legal_first_name: "Pat", email: "pat@example.com")
    end

    it "links the guardian straight to the document their child added" do
      doc = create(:custom_document, :optional, :minors_only, event: event, name: "Zip Lining Waiver")

      mail = described_class.optional_document_added(
        guardian_participant_event: guardian_participant_event, custom_document: doc
      )

      expect(mail.to).to eq([ "pat@example.com" ])
      expect(mail.subject).to include("Robin signed up for an optional activity at Midnight")
      expect(mail.body.encoded).to include("Zip Lining Waiver")
      expect(mail.body.encoded).to include("documents/#{doc.id}")
      # The guardian must be told this is opt-in, not something Robin missed.
      expect(mail.body.encoded).to include("optional")
    end

    it "explains the paper flow for a physical document" do
      doc = create(:custom_document, :optional, :physical, :dual_signer, event: event, name: "Hiking Waiver")

      mail = described_class.optional_document_added(
        guardian_participant_event: guardian_participant_event, custom_document: doc
      )

      expect(mail.body.encoded).to include("uploads a photo")
    end

    it "sends nothing while guardian invites are locked" do
      event.update!(guardian_invites_locked: true)
      doc = create(:custom_document, :optional, :minors_only, event: event)

      mail = described_class.optional_document_added(
        guardian_participant_event: guardian_participant_event, custom_document: doc
      )

      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end
  end
end
