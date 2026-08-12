require "rails_helper"

RSpec.describe DocusealJobs::CreateAdultWaiverJob, type: :job do
  let(:pe) { create(:participant_event) }

  it "does not create a second submission when a signing slug already exists" do
    consent = create(:consent, participant_event: pe, status: :sent,
      docuseal_participant_slug: "existing-slug")

    expect(Docuseal::Client).not_to receive(:for)

    described_class.perform_now(consent.id)

    expect(consent.reload.docuseal_participant_slug).to eq("existing-slug")
  end

  it "skips signed and voided consents" do
    consent = create(:consent, :signed, participant_event: pe)

    expect(Docuseal::Client).not_to receive(:for)

    described_class.perform_now(consent.id)
  end
end
