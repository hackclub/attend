require "rails_helper"

RSpec.describe Docuseal::WaiverTemplate do
  let(:event) { create(:event) }

  before do
    allow(Docuseal::HostConfig).to receive(:legacy_host).and_return("legacy.example.com")
  end

  describe ".id_for" do
    it "uses the event's configured template" do
      event.update!(docuseal_freedom_waiver_template_id: "42")

      expect(described_class.id_for(event: event, host: "selfhosted.example.com", kind: :freedom_waiver)).to eq("42")
    end

    it "falls back to the built-in template only on the legacy host" do
      expect(described_class.id_for(event: event, host: "legacy.example.com", kind: :freedom_waiver)).to eq(2274416)
      expect(described_class.id_for(event: event, host: "selfhosted.example.com", kind: :freedom_waiver)).to be_nil
    end

    it "prefers the event's waiver template for adults" do
      event.update!(docuseal_waiver_template_id: "7", docuseal_adult_waiver_template_id: "8")

      expect(described_class.id_for(event: event, host: "selfhosted.example.com", kind: :adult_waiver)).to eq("7")
    end
  end

  describe ".retry_failed?" do
    let(:participant_event) { create(:participant_event, event: event) }

    it "retries ordinary failures" do
      consent = create(:consent, participant_event: participant_event, status: :failed,
        failure_reason: "docuseal_error: boom")

      expect(described_class.retry_failed?(consent)).to be(true)
    end

    it "leaves a template failure alone until the event's template changes" do
      event.update!(docuseal_freedom_waiver_template_id: "42")
      consent = create(:consent, :freedom_waiver, participant_event: participant_event, status: :failed,
        docuseal_host: "selfhosted.example.com", docuseal_template_id: "42",
        failure_reason: "template_not_found: DocuSeal template 42 doesn't exist")

      expect(described_class.retry_failed?(consent)).to be(false)

      event.update!(docuseal_freedom_waiver_template_id: "43")
      expect(described_class.retry_failed?(consent.reload)).to be(true)
    end

    it "leaves an unconfigured template alone until one is set" do
      consent = create(:consent, :freedom_waiver, participant_event: participant_event, status: :failed,
        docuseal_host: "selfhosted.example.com", failure_reason: "template_not_configured: no freedom waiver template")

      expect(described_class.retry_failed?(consent)).to be(false)

      event.update!(docuseal_freedom_waiver_template_id: "43")
      expect(described_class.retry_failed?(consent.reload)).to be(true)
    end
  end
end
