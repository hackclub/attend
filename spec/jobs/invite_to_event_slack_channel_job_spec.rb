require "rails_helper"

RSpec.describe InviteToEventSlackChannelJob, type: :job do
  include ActiveJob::TestHelper

  let(:slack_service) { instance_double(SlackService) }

  before do
    allow(SlackService).to receive(:new).and_return(slack_service)
  end

  def registration(participant: create(:participant, slack_user_id: "U1"))
    create(:participant_event, event: create(:event, slack_channel_id: "C123"), participant: participant, status: :complete)
  end

  it "invites the participant and logs Slack errors instead of failing" do
    allow(slack_service).to receive(:invite_to_channel).and_raise(SlackService::Error, "not_in_channel")
    allow(Rails.logger).to receive(:error)

    expect { described_class.perform_now(registration.id) }.not_to raise_error
    expect(slack_service).to have_received(:invite_to_channel).with(channel_id: "C123", user_id: "U1")
    expect(Rails.logger).to have_received(:error).with(/Failed to add U1 to C123: not_in_channel/)
  end

  it "skips a participant banned after the registration completed" do
    allow(slack_service).to receive(:invite_to_channel)
    participant = create(:participant, slack_user_id: "U1")
    pe = registration(participant: participant)
    create(:ban, email: participant.email)

    described_class.perform_now(pe.id)

    expect(slack_service).not_to have_received(:invite_to_channel)
  end

  it "retries when Slack rate-limits it" do
    allow(slack_service).to receive(:invite_to_channel).and_raise(SlackService::RateLimited.new(30))
    pe = registration

    expect { described_class.perform_now(pe.id) }.to have_enqueued_job(described_class).with(pe.id)
  end
end
