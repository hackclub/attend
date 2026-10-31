require "rails_helper"

RSpec.describe SendIncidentUpdateToSlackJob do
  let(:incident) { create(:incident, slack_message_ts: "1700000000.000100") }
  let(:user) { create(:user) }
  let(:slack) { instance_double(SlackService, send_to_channel: true) }

  before { allow(SlackService).to receive(:new).and_return(slack) }

  it "posts a change the thread describes" do
    described_class.perform_now(incident.id, user.id, { "status" => %w[open resolved] })

    expect(slack).to have_received(:send_to_channel).with(hash_including(thread_ts: "1700000000.000100"))
  end

  it "posts nothing when no change is one it describes" do
    changes = { "occurred_at" => [ Time.utc(2026, 7, 12, 9, 30), Time.utc(2026, 7, 12, 13, 30) ] }

    expect { described_class.perform_now(incident.id, user.id, changes) }.not_to raise_error
    expect(slack).not_to have_received(:send_to_channel)
  end
end
