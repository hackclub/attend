require "rails_helper"

RSpec.describe "Slack OAuth callback", type: :request do
  let(:slack_service) { instance_double(SlackService) }
  let(:participant) { create(:participant) }
  let(:participant_event) do
    create(:participant_event, participant: participant, status: :complete,
                               event: create(:event, slack_channel_id: "C123"))
  end

  before do
    allow(SlackService).to receive(:new).and_return(slack_service)
    allow(slack_service).to receive(:decode_state).and_return(participant_event.id)
    allow(slack_service).to receive(:exchange_code_for_token)
      .and_return({ slack_user_id: "U1", team_id: "T1", team_name: "Hack Club" })
    allow(slack_service).to receive(:invite_to_channel)
  end

  it "adds the participant to the event channel" do
    get slack_oauth_callback_path, params: { code: "abc", state: "xyz" }

    expect(slack_service).to have_received(:invite_to_channel).with(channel_id: "C123", user_id: "U1")
    expect(participant.reload.slack_user_id).to eq("U1")
  end

  it "links Slack but skips the channel for a banned participant" do
    create(:ban, email: participant.email)

    get slack_oauth_callback_path, params: { code: "abc", state: "xyz" }

    expect(slack_service).not_to have_received(:invite_to_channel)
    expect(participant.reload.slack_user_id).to eq("U1")
    expect(response).to redirect_to(slack_success_path)
  end
end
