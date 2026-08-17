require "rails_helper"

RSpec.describe WalletPassUpdatable do
  let(:participant_event) { create(:participant_event) }
  let(:participant) { participant_event.participant }

  it "enqueues pass updates when a pass-rendered attribute changes" do
    expect {
      participant.update!(legal_first_name: "Newname")
    }.to have_enqueued_job(WalletPassUpdateJob).with(participant_event.id)
  end

  it "skips the fan-out when no pass-rendered attribute changed" do
    expect {
      participant.update!(city: "Vienna")
    }.not_to have_enqueued_job(WalletPassUpdateJob)
  end

  it "always enqueues for models without an attribute allowlist" do
    expect {
      participant_event.event.update!(name: "Renamed Event")
    }.to have_enqueued_job(WalletPassUpdateJob).with(participant_event.id)
  end
end
