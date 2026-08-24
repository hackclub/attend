require "rails_helper"

RSpec.describe SyncSlackChannelJob, type: :job do
  include ActiveJob::TestHelper

  let(:event) { create(:event, slack_channel_id: "C123") }
  let(:slack_service) { instance_double(SlackService) }

  before do
    allow(SlackService).to receive(:new).and_return(slack_service)
    stub_const("SyncSlackChannelJob::INVITE_PAUSE", 0)
  end

  def create_complete_pe(slack_user_id: nil)
    participant = create(:participant)
    participant.update!(slack_user_id: slack_user_id) if slack_user_id
    create(:participant_event, event: event, participant: participant, status: :complete)
  end

  it "invites completed participants with linked Slack accounts and records the sync" do
    invited = create_complete_pe(slack_user_id: "U1")
    member = create_complete_pe(slack_user_id: "U2")
    failing = create_complete_pe(slack_user_id: "U3")
    create_complete_pe # no slack id — must not be invited
    create(:participant_event, event: event, participant: create(:participant).tap { |p| p.update!(slack_user_id: "U4") }) # not complete

    allow(slack_service).to receive(:invite_to_channel).with(channel_id: "C123", user_id: "U1").and_return({ success: true })
    allow(slack_service).to receive(:invite_to_channel).with(channel_id: "C123", user_id: "U2").and_return({ success: true, already_member: true })
    allow(slack_service).to receive(:invite_to_channel).with(channel_id: "C123", user_id: "U3").and_raise(SlackService::Error, "nope")

    broadcasts = []
    allow(ActionCable.server).to receive(:broadcast) { |stream, payload| broadcasts << [ stream, payload ] }

    described_class.perform_now(event.id)

    expect(slack_service).to have_received(:invite_to_channel).exactly(3).times
    expect(event.reload.last_slack_sync_at).to be_present

    final = broadcasts.last
    expect(final[0]).to eq("slack_sync_#{event.id}")
    expect(final[1]).to include(status: "completed", added: 1, already_member: 1, failed: 1)
  end

  it "emails completed participants without Slack accounts when send_emails is set" do
    create_complete_pe # without slack id
    allow(slack_service).to receive(:invite_to_channel)

    expect {
      described_class.perform_now(event.id, send_emails: true)
    }.to have_enqueued_job(ActionMailer::Base.delivery_job)
      .with("ParticipantMailer", "slack_link_reminder", "deliver_now", anything)
  end

  it "does nothing when the event has no Slack channel" do
    event.update!(slack_channel_id: nil)

    described_class.perform_now(event.id)

    expect(SlackService).not_to have_received(:new)
  end
end
