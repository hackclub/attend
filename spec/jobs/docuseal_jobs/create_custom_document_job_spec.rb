require "rails_helper"

RSpec.describe DocusealJobs::CreateCustomDocumentJob, type: :job do
  let(:event) { create(:event) }
  let(:pe) { create(:participant_event, event: event) }
  let(:custom_document) { create(:custom_document, event: event, docuseal_template_id: "9999") }

  def create_custom_consent(**attrs)
    create(:consent, participant_event: pe, consent_type: :custom_document,
      custom_document: custom_document, **attrs)
  end

  it "does not create a second submission when one already exists" do
    consent = create_custom_consent(status: :sent, docuseal_envelope_id: "sub-1")

    expect(Docuseal::Client).not_to receive(:for)

    described_class.perform_now(consent.id)
  end

  it "skips signed and voided consents" do
    consent = create_custom_consent(status: :signed)

    expect(Docuseal::Client).not_to receive(:for)

    described_class.perform_now(consent.id)
  end

  it "fails guardian-only documents when the participant has no guardian" do
    guardian_doc = create(:custom_document, :guardian_only, event: event)
    consent = create(:consent, participant_event: pe, consent_type: :custom_document,
      custom_document: guardian_doc)

    expect(Docuseal::Client).not_to receive(:for)

    described_class.perform_now(consent.id)

    expect(consent.reload).to be_failed
    expect(consent.failure_reason).to eq("no_guardian_available")
  end

  describe "creating a submission" do
    let(:client) { instance_double(Docuseal::Client) }

    before do
      allow(Docuseal::Client).to receive(:for).and_return(client)
      allow(client).to receive(:get_template).with("9999").and_return(
        "submitters" => [ { "name" => "Attendee" } ],
        "fields" => [ { "name" => "Attendee Name" } ]
      )
    end

    it "creates a participant submission with prefilled fields from configured mappings" do
      event.update!(docuseal_field_mappings: {
        custom_document.mapping_key => {
          "mappings" => [
            { "field_name" => "Attendee Name", "source_key" => "participant.full_name", "readonly" => true, "role" => "Attendee" }
          ]
        }
      })
      consent = create_custom_consent

      expect(client).to receive(:create_submission) do |args|
        expect(args[:template_id]).to eq("9999")
        expect(args[:submitters].length).to eq(1)
        submitter = args[:submitters].first
        expect(submitter[:role]).to eq("Attendee")
        expect(submitter[:email]).to eq(pe.participant.email)
        expect(submitter[:send_email]).to be false
        expect(submitter[:fields]).to eq([
          { name: "Attendee Name", default_value: pe.participant.full_name, readonly: true }
        ])
        expect(args[:metadata][:consent_id]).to eq(consent.id)
        [ { "submission_id" => "sub-42", "slug" => "slug-42", "role" => "Attendee" } ]
      end

      described_class.perform_now(consent.id)

      consent.reload
      expect(consent).to be_sent
      expect(consent.docuseal_envelope_id).to eq("sub-42")
      expect(consent.docuseal_participant_slug).to eq("slug-42")
      expect(consent.docuseal_template_id).to eq("9999")
      expect(consent.pending_on).to eq("participant")
    end

    it "adds an emailed guardian submitter for dual-signer documents" do
      allow(client).to receive(:get_template).and_return(
        "submitters" => [ { "name" => "Attendee" }, { "name" => "Legal Guardian" } ],
        "fields" => []
      )
      dual_doc = create(:custom_document, :dual_signer, event: event, docuseal_template_id: "9999")
      gpe = create(:guardian_participant_event, participant_event: pe)
      consent = create(:consent, participant_event: pe, consent_type: :custom_document,
        custom_document: dual_doc)

      expect(client).to receive(:create_submission) do |args|
        roles = args[:submitters].map { |s| s[:role] }
        expect(roles).to eq([ "Attendee", "Legal Guardian" ])
        guardian_submitter = args[:submitters].last
        expect(guardian_submitter[:email]).to eq(gpe.guardian.email)
        expect(guardian_submitter[:send_email]).to be true
        [
          { "submission_id" => "sub-43", "slug" => "p-slug", "role" => "Attendee" },
          { "submission_id" => "sub-43", "slug" => "g-slug", "role" => "Legal Guardian" }
        ]
      end

      described_class.perform_now(consent.id)

      consent.reload
      expect(consent.docuseal_participant_slug).to eq("p-slug")
      expect(consent.docuseal_guardian_slug).to eq("g-slug")
      expect(consent.guardian_participant_event).to eq(gpe)
    end

    it "skips the guardian email when the guardian initiates from the portal" do
      allow(client).to receive(:get_template).and_return(
        "submitters" => [ { "name" => "Legal Guardian" } ],
        "fields" => []
      )
      guardian_doc = create(:custom_document, :guardian_only, event: event, docuseal_template_id: "9999")
      gpe = create(:guardian_participant_event, participant_event: pe)
      consent = create(:consent, participant_event: pe, consent_type: :custom_document,
        custom_document: guardian_doc)

      expect(client).to receive(:create_submission) do |args|
        expect(args[:submitters].length).to eq(1)
        submitter = args[:submitters].first
        expect(submitter[:email]).to eq(gpe.guardian.email)
        # The guardian is signing embedded on the portal — no DocuSeal email
        expect(submitter[:send_email]).to be false
        [ { "submission_id" => "sub-44", "slug" => "g-slug", "role" => "Legal Guardian" } ]
      end

      described_class.perform_now(consent.id, "guardian")

      consent.reload
      expect(consent.docuseal_guardian_slug).to eq("g-slug")
      expect(consent.pending_on).to eq("guardian")
    end

    it "falls back to participant-only for dual-signer documents without a guardian" do
      dual_doc = create(:custom_document, :dual_signer, event: event, docuseal_template_id: "9999")
      consent = create(:consent, participant_event: pe, consent_type: :custom_document,
        custom_document: dual_doc)

      expect(client).to receive(:create_submission) do |args|
        expect(args[:submitters].length).to eq(1)
        [ { "submission_id" => "sub-46", "slug" => "p-slug", "role" => "Attendee" } ]
      end

      described_class.perform_now(consent.id)

      expect(consent.reload).to be_sent
    end

    it "marks the consent failed on validation errors" do
      consent = create_custom_consent

      Docuseal::Error # load error.rb so its subclasses are defined
      allow(client).to receive(:create_submission)
        .and_raise(Docuseal::ValidationError.new("bad template"))

      described_class.perform_now(consent.id)

      expect(consent.reload).to be_failed
      expect(consent.failure_reason).to include("validation_error")
    end
  end
end
