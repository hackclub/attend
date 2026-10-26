require "rails_helper"

RSpec.describe RegenerateWaiversForDateChangeJob do
  let(:event) { create(:event) }
  let(:client) { instance_double(Docuseal::Client, archive_submission: true) }

  before { allow(Docuseal::Client).to receive(:for).and_return(client) }

  def issued_waiver(status: :sent)
    create(:consent, participant_event: create(:participant_event, event: event),
      status: status, docuseal_envelope_id: "sub_#{SecureRandom.hex(4)}")
  end

  it "re-issues each participant's waivers" do
    unsigned = issued_waiver
    signed = issued_waiver(status: :signed)

    described_class.perform_now(event.id, include_signed: false)

    expect(unsigned.reload).to be_pending
    expect(signed.reload).to be_signed
  end

  it "keeps going when one participant fails" do
    first = issued_waiver
    second = issued_waiver

    original = Docuseal::WaiverDateRegeneration.instance_method(:reissue!)
    allow_any_instance_of(Docuseal::WaiverDateRegeneration).to receive(:reissue!) do |regeneration, participant_event, consents|
      raise "boom" if participant_event == first.participant_event

      original.bind_call(regeneration, participant_event, consents)
    end

    expect { described_class.perform_now(event.id, include_signed: true) }.not_to raise_error
    expect(second.reload).to be_pending
  end
end
