require "rails_helper"

RSpec.describe DocusealJobs::CreateFreedomWaiverJob, type: :job do
  let(:pe) { create(:participant_event) }

  it "does not create a second submission when a guardian signing slug already exists" do
    consent = create(:consent, :freedom_waiver, participant_event: pe, status: :sent,
      docuseal_guardian_slug: "existing-slug")

    expect(Docuseal::Client).not_to receive(:for)

    described_class.perform_now(consent.id)

    expect(consent.reload.docuseal_guardian_slug).to eq("existing-slug")
  end
end
