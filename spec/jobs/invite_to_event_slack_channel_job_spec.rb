require "rails_helper"

RSpec.describe InviteToEventSlackChannelJob, type: :job do
  include ActiveJob::TestHelper

  let(:event) { create(:event, slack_channel_id: "C123") }
  let(:participant) { create(:participant, slack_user_id: "U1") }
  let(:slack_service) { instance_double(SlackService) }

  before do
    allow(SlackService).to receive(:new).and_return(slack_service)
    allow(slack_service).to receive(:invite_to_channel).and_return({ success: true })
  end

  def registration(status: :complete, evt: event, person: participant)
    create(:participant_event, event: evt, participant: person, status: status)
  end

  it "invites a completed participant to their event's channel" do
    described_class.perform_now(registration.id)

    expect(slack_service).to have_received(:invite_to_channel).with(channel_id: "C123", user_id: "U1")
  end

  it "skips registrations that aren't complete, events without a channel, and participants without Slack" do
    described_class.perform_now(registration(status: :in_progress).id)
    described_class.perform_now(registration(evt: create(:event)).id)
    described_class.perform_now(registration(person: create(:participant)).id)
    described_class.perform_now(SecureRandom.uuid)

    expect(slack_service).not_to have_received(:invite_to_channel)
  end

  it "logs Slack errors instead of failing" do
    allow(slack_service).to receive(:invite_to_channel).and_raise(SlackService::Error, "not_in_channel")
    allow(Rails.logger).to receive(:error)

    expect { described_class.perform_now(registration.id) }.not_to raise_error
    expect(Rails.logger).to have_received(:error).with(/Failed to add U1 to C123: not_in_channel/)
  end

  it "retries when Slack rate-limits it" do
    allow(slack_service).to receive(:invite_to_channel).and_raise(SlackService::RateLimited.new(30))
    pe = registration

    expect { described_class.perform_now(pe.id) }.to have_enqueued_job(described_class).with(pe.id)
  end
end
