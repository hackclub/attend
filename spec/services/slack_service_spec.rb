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

  describe "#channel_member_ids" do
    it "follows Slack's cursor across pages, form-encoded" do
      stub_request(:post, "https://slack.com/api/conversations.members")
        .with(body: { "channel" => "CORG", "limit" => "1000" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { ok: true, members: %w[UONE UTWO], response_metadata: { next_cursor: "page2" } }.to_json)
      stub_request(:post, "https://slack.com/api/conversations.members")
        .with(body: { "channel" => "CORG", "limit" => "1000", "cursor" => "page2" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { ok: true, members: %w[UTHREE], response_metadata: { next_cursor: "" } }.to_json)

      expect(service.channel_member_ids(channel_id: "CORG")).to eq(Set["UONE", "UTWO", "UTHREE"])
    end

    it "raises when Slack won't list the channel" do
      stub_slack("conversations.members", body: { ok: false, error: "missing_scope" })

      expect { service.channel_member_ids(channel_id: "CORG") }.to raise_error(SlackService::Error, /missing_scope/)
    end
  end

  describe "#remove_from_channel" do
    it "treats not_in_channel as not a member" do
      stub_slack("conversations.kick", body: { ok: false, error: "not_in_channel" })

      expect(service.remove_from_channel(channel_id: "CORG", user_id: "UONE")).to include(not_member: true)
    end
  end
end
