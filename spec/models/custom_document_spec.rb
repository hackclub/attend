require "rails_helper"

RSpec.describe CustomDocument, type: :model do
  it "requires a name and template id" do
    doc = build(:custom_document, name: nil, docuseal_template_id: nil)
    expect(doc).not_to be_valid
    expect(doc.errors[:name]).to be_present
    expect(doc.errors[:docuseal_template_id]).to be_present
  end

  it "uses a custom_-prefixed mapping key shared with the docuseal_templates routes" do
    doc = create(:custom_document)
    expect(doc.mapping_key).to eq("custom_#{doc.id}")
  end

  it "exposes signer helpers" do
    expect(build(:custom_document).participant_signs?).to be true
    expect(build(:custom_document).guardian_signs?).to be false
    expect(build(:custom_document, :guardian_only).guardian_signs?).to be true
    expect(build(:custom_document, :guardian_only).participant_signs?).to be false
    expect(build(:custom_document, :dual_signer).participant_signs?).to be true
    expect(build(:custom_document, :dual_signer).guardian_signs?).to be true
    expect(build(:custom_document, :minors_only).participant_signs?).to be true
    expect(build(:custom_document, :minors_only).guardian_signs?).to be true
  end

  describe "physical documents" do
    it "requires an uploaded PDF instead of a DocuSeal template id" do
      doc = build(:custom_document, document_kind: "physical", docuseal_template_id: nil)
      expect(doc).not_to be_valid
      expect(doc.errors[:template_pdf]).to be_present
      expect(doc.errors[:docuseal_template_id]).to be_blank

      expect(build(:custom_document, :physical)).to be_valid
    end

    it "rejects non-PDF template uploads" do
      doc = build(:custom_document, document_kind: "physical", docuseal_template_id: nil)
      doc.template_pdf.attach(io: StringIO.new("nope"), filename: "form.png", content_type: "image/png")
      expect(doc).not_to be_valid
      expect(doc.errors[:template_pdf]).to be_present
    end

    it "parses the template PDF and stores its page count" do
      doc = create(:custom_document, :physical, pages: 3)
      expect(doc.template_page_count).to eq(3)
    end

    it "rejects garbage bytes labelled application/pdf" do
      doc = build(:custom_document, document_kind: "physical", docuseal_template_id: nil)
      doc.template_pdf.attach(io: StringIO.new("%PDF-1.4 test"), filename: "form.pdf", content_type: "application/pdf")

      expect(doc).not_to be_valid
      expect(doc.errors[:template_pdf]).to include("must be a valid PDF")
    end

    describe "#guardian_verifies?" do
      let(:event) { create(:event) }
      let(:minor_pe) { create(:participant_event, event: event) }
      let(:adult_pe) do
        create(:participant_event, event: event).tap { |pe| pe.participant.update!(date_of_birth: 18.years.ago - 1.month) }
      end

      it "requires guardian confirmation only for physical guardian-signed documents on minors" do
        physical_dual = build(:custom_document, :physical, :dual_signer, event: event)
        physical_participant = build(:custom_document, :physical, event: event)
        electronic_dual = build(:custom_document, :dual_signer, event: event)

        expect(physical_dual.guardian_verifies?(minor_pe)).to be true
        expect(physical_dual.guardian_verifies?(adult_pe)).to be false
        expect(physical_participant.guardian_verifies?(minor_pe)).to be false
        expect(electronic_dual.guardian_verifies?(minor_pe)).to be false
      end
    end
  end

  describe "#applies_to?" do
    let(:event) { create(:event) }
    let(:minor_pe) { create(:participant_event, event: event) }
    let(:adult_pe) do
      create(:participant_event, event: event).tap { |pe| pe.participant.update!(date_of_birth: 18.years.ago - 1.month) }
    end

    it "excludes guardian-only documents for adults and includes everything else" do
      guardian_doc = build(:custom_document, :guardian_only, event: event)
      dual_doc = build(:custom_document, :dual_signer, event: event)

      expect(guardian_doc.applies_to?(minor_pe)).to be true
      expect(guardian_doc.applies_to?(adult_pe)).to be false
      expect(dual_doc.applies_to?(adult_pe)).to be true
    end

    it "skips minors-only documents entirely for adults" do
      minors_doc = build(:custom_document, :minors_only, event: event)

      expect(minors_doc.applies_to?(minor_pe)).to be true
      expect(minors_doc.applies_to?(adult_pe)).to be false
    end
  end

  describe "completion gating on ParticipantEvent" do
    let(:event) { create(:event) }
    let(:pe) { create(:participant_event, event: event) }

    it "blocks custom_documents_signed? until every applicable document has a signed consent" do
      doc = create(:custom_document, event: event)
      expect(pe.custom_documents_signed?).to be false
      expect(pe.onboarding_progress[:steps].map { |s| s[:name] }).to include("custom_documents")

      create(:consent, :signed, participant_event: pe, consent_type: :custom_document, custom_document: doc)
      expect(pe.reload.custom_documents_signed?).to be true
    end

    it "ignores archived documents and inapplicable guardian-only documents" do
      create(:custom_document, :archived, event: event)
      adult_pe = create(:participant_event, event: event).tap { |p| p.participant.update!(date_of_birth: 18.years.ago - 1.month) }
      create(:custom_document, :guardian_only, event: event)

      expect(pe.custom_documents_signed?).to be false # minor: guardian doc applies
      expect(adult_pe.custom_documents_signed?).to be true
      expect(adult_pe.onboarding_progress[:steps].map { |s| s[:name] }).not_to include("custom_documents")
    end
  end

  it "is excluded from the active scope once archived" do
    doc = create(:custom_document)
    expect(CustomDocument.active).to include(doc)

    doc.archive!
    expect(CustomDocument.active).not_to include(doc)
  end

  it "builds a field mapper backed by the event's docuseal_field_mappings" do
    doc = create(:custom_document)
    doc.event.update!(docuseal_field_mappings: {
      doc.mapping_key => { "mappings" => [ { "field_name" => "Full Name", "source_key" => "participant.full_name" } ] }
    })

    expect(doc.field_mapper.has_mappings?).to be true
  end

  it "cannot be destroyed while consents reference it" do
    consent = create(:consent, :custom_document)
    doc = consent.custom_document

    expect(doc.destroy).to be false
    expect(doc.errors[:base]).to be_present
  end
end
