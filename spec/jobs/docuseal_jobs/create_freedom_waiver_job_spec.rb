require "rails_helper"

RSpec.describe DocusealJobs::CreateFreedomWaiverJob, type: :job do
  include ActiveJob::TestHelper

  let(:event) { create(:event, freedom_waivers_enabled: true, docuseal_freedom_waiver_template_id: "42") }
  let(:pe) { create(:participant_event, event: event) }

  it "does not create a second submission when a guardian signing slug already exists" do
    consent = create(:consent, :freedom_waiver, participant_event: pe, status: :sent,
      docuseal_guardian_slug: "existing-slug")

    expect(Docuseal::Client).not_to receive(:for)

    described_class.perform_now(consent.id)

    expect(consent.reload.docuseal_guardian_slug).to eq("existing-slug")
  end

  context "with a guardian" do
    let!(:gpe) { create(:guardian_participant_event, participant_event: pe) }
    let(:consent) { create(:consent, :freedom_waiver, participant_event: pe, status: :pending) }
    let(:client) { instance_double(Docuseal::Client) }

    before { allow(Docuseal::Client).to receive(:for).and_return(client) }

    it "marks the consent failed without raising when the template doesn't exist" do
      allow(client).to receive(:get_template).and_raise(Docuseal::NotFoundError.new("Resource not found", status: 404))

      expect { described_class.perform_now(consent.id) }.not_to raise_error

      consent.reload
      expect(consent).to be_failed
      expect(consent.failure_reason).to start_with("template_not_found: DocuSeal template 42")
      expect(consent.docuseal_template_id).to eq("42")
      expect(described_class).not_to have_been_enqueued.with(consent.id)
    end

    it "doesn't call DocuSeal when no template is configured off the legacy host" do
      event.update!(docuseal_freedom_waiver_template_id: nil)
      allow(Docuseal::WaiverTemplate).to receive(:legacy_host?).and_return(false)

      expect(client).not_to receive(:get_template)
      described_class.perform_now(consent.id)

      expect(consent.reload.failure_reason).to start_with("template_not_configured")
    end

    it "retries DocuSeal outages with backoff, leaving the consent pending" do
      allow(client).to receive(:get_template).and_raise(Docuseal::ServerError.new("Service Unavailable", status: 503))

      expect { described_class.perform_now(consent.id) }.not_to raise_error

      expect(consent.reload).to be_pending
      expect(described_class).to have_been_enqueued.with(consent.id)
    end

    it "marks the consent failed and reports once the retries run out" do
      allow(client).to receive(:get_template).and_raise(Docuseal::ServerError.new("Service Unavailable", status: 503))

      # perform_enqueued_jobs wraps the job's error in a Minitest::UnexpectedError
      expect {
        perform_enqueued_jobs { described_class.perform_later(consent.id) }
      }.to raise_error { |error| expect(error.try(:error) || error).to be_a(Docuseal::ServerError) }

      expect(client).to have_received(:get_template).exactly(5).times
      expect(consent.reload).to be_failed
      expect(consent.failure_reason).to eq("docuseal_error: Service Unavailable")
    end
  end
end
