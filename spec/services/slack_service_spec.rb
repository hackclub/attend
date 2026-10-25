require "rails_helper"

RSpec.describe SlackService do
  let(:service) { described_class.new(bot_token: "xoxb-test") }

  def stub_slack(method, status: 200, body: { ok: true }, headers: {})
    stub_request(:post, "https://slack.com/api/#{method}")
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" }.merge(headers))
  end

  describe "#invite_to_channel" do
    it "raises RateLimited with Slack's Retry-After on a 429" do
      stub_slack("conversations.invite", status: 429, body: { ok: false, error: "ratelimited" }, headers: { "Retry-After" => "7" })

      expect { service.invite_to_channel(channel_id: "CORG", user_id: "UONE") }
        .to raise_error(SlackService::RateLimited) { |e| expect(e.retry_after).to eq(7) }
    end

    it "raises NotInWorkspace for an Enterprise user outside the channel's workspace" do
      stub_slack("conversations.invite", body: { ok: false, error: "org_user_not_in_team" })

      expect { service.invite_to_channel(channel_id: "CORG", user_id: "UONE") }
        .to raise_error(SlackService::NotInWorkspace)
    end

    it "reports people already in the channel" do
      stub_slack("conversations.invite", body: { ok: false, error: "already_in_channel" })

      expect(service.invite_to_channel(channel_id: "CORG", user_id: "UONE")).to include(already_member: true)
    end
  end

  describe "#remove_from_channel" do
    it "treats not_in_channel as not a member" do
      stub_slack("conversations.kick", body: { ok: false, error: "not_in_channel" })

      expect(service.remove_from_channel(channel_id: "CORG", user_id: "UONE")).to include(not_member: true)
    end
  end
end
