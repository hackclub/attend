require "rails_helper"

RSpec.describe WalletPassUpdateService do
  include ActiveSupport::Testing::TimeHelpers

  let(:participant_event) { create(:participant_event) }
  let!(:pass) do
    Passkit::Pass.create!(
      klass: "Passkit::EventTicket",
      generator: participant_event,
      serial_number: SecureRandom.uuid,
      authentication_token: SecureRandom.hex(16)
    )
  end
  let(:service) { described_class.new(participant_event) }

  before do
    allow(service).to receive(:update_google_wallet)
    allow(service).to receive(:notify_apple_devices)
  end

  it "pushes a pass the first time, since there is nothing to compare against" do
    service.update_all

    expect(service).to have_received(:notify_apple_devices).with(pass)
    expect(pass.reload.content_digest).to be_present
  end

  it "doesn't push when nothing on the pass changed" do
    WalletPassContent.refresh!(pass)
    participant_event.participant.update!(pronouns: "they/them")

    service.update_all

    expect(service).not_to have_received(:notify_apple_devices)
  end

  it "pushes and moves last-modified when something on the pass changed" do
    WalletPassContent.refresh!(pass)
    before_change = pass.reload.last_update

    travel 1.minute do
      participant_event.participant.update!(tshirt_size: "xl")
      service.update_all
    end

    expect(service).to have_received(:notify_apple_devices).with(pass)
    expect(pass.reload.last_update).to be > before_change
  end
end
