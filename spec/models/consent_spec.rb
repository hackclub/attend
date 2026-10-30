require "rails_helper"

RSpec.describe Consent do
  describe "#signed_documents" do
    it "falls back to document_url for consents signed before documents were stored" do
      consent = build(:consent, document_url: "https://example.com/doc.pdf")

      expect(consent.signed_documents).to eq([ { "name" => nil, "url" => "https://example.com/doc.pdf" } ])
    end

    it "is empty when nothing was stored" do
      expect(build(:consent).signed_documents).to eq([])
    end
  end

  describe "wallet pass updates" do
    let(:consent) { create(:consent) }

    it "skips the pass push when only the signed documents changed" do
      expect {
        consent.update!(documents: [ { "name" => "Waiver", "url" => "https://example.com/w.pdf" } ],
          document_url: "https://example.com/w.pdf")
      }.not_to have_enqueued_job(WalletPassUpdateJob)
    end

    it "still pushes when the signature state changes" do
      expect { consent.update!(status: :signed) }.to have_enqueued_job(WalletPassUpdateJob).with(consent.participant_event_id)
    end
  end

  describe ".documents_from_docuseal" do
    it "trims stray whitespace from DocuSeal's document names" do
      expect(described_class.documents_from_docuseal([ { "name" => " Guardian", "url" => "u" } ]))
        .to eq([ { "name" => "Guardian", "url" => "u" } ])
    end
  end

  describe "#refresh_documents_from_docuseal!" do
    let(:client) { instance_double(Docuseal::Client) }
    let(:consent) do
      create(:consent, :signed, docuseal_envelope_id: "sub_1", document_url: "https://example.com/stale.pdf")
    end

    before { allow(Docuseal::Client).to receive(:for).and_return(client) }

    it "stores every document DocuSeal returns" do
      allow(client).to receive(:get_submission_documents).with("sub_1").and_return(
        "id" => 1,
        "documents" => [
          { "name" => "Waiver", "url" => "https://example.com/waiver.pdf" },
          { "name" => "Photo Release", "url" => "https://example.com/photo.pdf" }
        ]
      )

      documents = consent.refresh_documents_from_docuseal!

      expect(documents.map { |d| d["name"] }).to eq([ "Waiver", "Photo Release" ])
      expect(consent.reload.documents).to eq(documents)
      expect(consent.document_url).to eq("https://example.com/waiver.pdf")
    end

    it "keeps what is on file when DocuSeal can't be reached" do
      allow(client).to receive(:get_submission_documents).and_raise(Docuseal::Error, "down")

      expect(consent.refresh_documents_from_docuseal!).to eq([ { "name" => nil, "url" => "https://example.com/stale.pdf" } ])
      expect(consent.reload.documents).to eq([])
    end
  end

  describe "#reset_for_reissue!" do
    let(:participant_event) { create(:participant_event) }
    let(:guardian_participant_event) { create(:guardian_participant_event, participant_event: participant_event) }
    let(:consent) do
      create(:consent, participant_event: participant_event, guardian_participant_event: guardian_participant_event,
        status: :signed, docuseal_envelope_id: "sub_old", docuseal_participant_slug: "p", docuseal_guardian_slug: "g",
        docuseal_template_id: "100", docuseal_host: "https://old.example.com", signed_at: 1.day.ago,
        participant_signed_at: 2.days.ago, guardian_signed_at: 1.day.ago, document_url: "https://old.example.com/doc.pdf",
        documents: [ { "name" => "Waiver", "url" => "https://old.example.com/doc.pdf" } ],
        failure_reason: "earlier", pending_on: "guardian", sent_at: 3.days.ago)
    end

    it "clears every trace of the old submission but keeps the guardian and host" do
      consent.reset_for_reissue!
      consent.reload

      expect(consent).to be_pending
      expect(consent.attributes.slice(
        "docuseal_envelope_id", "docuseal_participant_slug", "docuseal_guardian_slug", "docuseal_template_id",
        "signed_at", "participant_signed_at", "guardian_signed_at", "document_url", "failure_reason", "pending_on", "sent_at"
      ).values).to all(be_nil)
      expect(consent.documents).to eq([])
      expect(consent.guardian_participant_event).to eq(guardian_participant_event)
      expect(consent.docuseal_host).to eq("https://old.example.com")
    end

    it "moves the consent to another DocuSeal host when asked" do
      consent.reset_for_reissue!(docuseal_host: "https://new.example.com")

      expect(consent.reload.docuseal_host).to eq("https://new.example.com")
    end

    it "makes the guardian choose again on a freedom waiver" do
      safeguarding_info = SafeguardingInfo.create!(participant_event: participant_event, freedom_waiver_granted: true)
      consent.update!(consent_type: :freedom_waiver)

      consent.reset_for_reissue!

      expect(safeguarding_info.reload.freedom_waiver_granted).to be(false)
    end

    it "leaves the freedom waiver choice alone when resetting the main waiver" do
      safeguarding_info = SafeguardingInfo.create!(participant_event: participant_event, freedom_waiver_granted: true)

      consent.reset_for_reissue!

      expect(safeguarding_info.reload.freedom_waiver_granted).to be(true)
    end
  end

  describe "#signing_guardian_participant_event" do
    let(:participant_event) { create(:participant_event) }
    let!(:first_guardian) { create(:guardian_participant_event, participant_event: participant_event, created_at: 2.days.ago) }
    let!(:replacement_guardian) { create(:guardian_participant_event, participant_event: participant_event) }

    it "prefers the guardian the consent was issued to" do
      consent = create(:consent, participant_event: participant_event, guardian_participant_event: replacement_guardian)

      expect(consent.signing_guardian_participant_event).to eq(replacement_guardian)
    end

    it "falls back to the participant's first guardian, like the waiver jobs" do
      consent = create(:consent, participant_event: participant_event)

      expect(consent.signing_guardian_participant_event).to eq(first_guardian)
    end
  end
end
