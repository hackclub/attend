require "rails_helper"

RSpec.describe SyncOrgSupportSlackChannelJob, type: :job do
  include ActiveJob::TestHelper

  let(:slack_service) { instance_double(SlackService) }
  let(:upcoming_event) { create(:event) }
  let(:just_ended_event) { create(:event, starts_at: 5.days.ago, ends_at: 3.days.ago) }
  let(:long_ended_event) { create(:event, starts_at: 3.weeks.ago, ends_at: 2.weeks.ago) }

  before do
    Setting.org_support_slack_channel_id = "CORG"
    allow(SlackService).to receive(:new).and_return(slack_service)
    allow(slack_service).to receive(:invite_to_channel).and_return({ success: true })
    allow(slack_service).to receive(:remove_from_channel).and_return({ success: true })
    stub_const("SyncOrgSupportSlackChannelJob::SLACK_PAUSE", 0)
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  def slack_user(slack_id = "U#{SecureRandom.hex(3).upcase}", **attrs)
    create(:user, oidc_claims: slack_id ? { "slack_id" => slack_id } : {}, **attrs)
  end

  def staff(role, event: upcoming_event, slack_id: "U#{SecureRandom.hex(3).upcase}")
    user = slack_user(slack_id)
    create(:event_role_assignment, user: user, event: event, role: role)
    user
  end

  def expect_invited(user)
    expect(slack_service).to have_received(:invite_to_channel).with(channel_id: "CORG", user_id: user.verified_slack_id)
  end

  it "invites every event role, limited and read-only included" do
    invited = EventRoleAssignment.roles.keys.map { |role| staff(role) }

    described_class.perform_now

    invited.each { |user| expect_invited(user) }
    expect(SlackChannelInvite.where(channel_id: "CORG").pluck(:user_id)).to match_array(invited.map(&:id))
  end

  it "invites global admins and global read-only users" do
    admin = slack_user(global_role: "global_admin")
    viewer = slack_user(global_role: "read_only")
    nobody = slack_user

    described_class.perform_now

    expect_invited(admin)
    expect_invited(viewer)
    expect(User.org_support_channel_members).not_to include(nobody)
  end

  it "invites series members while an event in the series is on" do
    series = create(:event_series)
    create(:event, event_series: series)
    member = slack_user
    create(:series_role_assignment, user: member, event_series: series)

    described_class.perform_now

    expect_invited(member)
  end

  it "keeps staff for 7 days after the event ends, then not" do
    recent = staff("limited", event: just_ended_event)
    old = staff("event_admin", event: long_ended_event)

    expect(User.org_support_channel_members).to include(recent)
    expect(User.org_support_channel_members).not_to include(old)
  end

  it "removes people it added once their events are over the grace period" do
    old = staff("ops", event: long_ended_event)
    SlackChannelInvite.create!(user: old, channel_id: "CORG", slack_user_id: old.verified_slack_id)

    described_class.perform_now

    expect(slack_service).to have_received(:remove_from_channel).with(channel_id: "CORG", user_id: old.verified_slack_id)
    expect(SlackChannelInvite.exists?(user: old)).to be(false)
    expect(Setting.org_support_slack_last_sync).to include("removed" => 1)
  end

  it "never removes people who were already in the channel" do
    member = staff("event_admin")
    allow(slack_service).to receive(:invite_to_channel).and_return({ success: true, already_member: true })

    described_class.perform_now
    expect(SlackChannelInvite.exists?(user: member)).to be(false)

    member.event_role_assignments.destroy_all
    described_class.perform_now

    expect(slack_service).not_to have_received(:remove_from_channel)
  end

  it "removes people who lost their role, and leaves invites for other channels alone" do
    ex_staff = slack_user
    SlackChannelInvite.create!(user: ex_staff, channel_id: "CORG", slack_user_id: ex_staff.verified_slack_id)
    SlackChannelInvite.create!(user: ex_staff, channel_id: "COTHER", slack_user_id: ex_staff.verified_slack_id)

    described_class.perform_now

    expect(slack_service).to have_received(:remove_from_channel).once
    expect(SlackChannelInvite.where(user: ex_staff).pluck(:channel_id)).to eq([ "COTHER" ])
  end

  it "removes a deleted user's Slack account" do
    member = staff("event_admin")
    described_class.perform_now
    slack_id = member.verified_slack_id

    member.destroy!
    expect(SlackChannelInvite.find_by(slack_user_id: slack_id).user_id).to be_nil
    described_class.perform_now

    expect(slack_service).to have_received(:remove_from_channel).with(channel_id: "CORG", user_id: slack_id)
    expect(SlackChannelInvite.exists?(slack_user_id: slack_id)).to be(false)
  end

  it "removes the old Slack account when someone's Slack ID changes" do
    member = staff("event_admin", slack_id: "UOLDID")
    described_class.perform_now

    member.update!(oidc_claims: { "slack_id" => "UNEWID" })
    described_class.perform_now

    expect(slack_service).to have_received(:invite_to_channel).with(channel_id: "CORG", user_id: "UNEWID")
    expect(slack_service).to have_received(:remove_from_channel).with(channel_id: "CORG", user_id: "UOLDID").once
    expect(SlackChannelInvite.where(user: member).pluck(:slack_user_id)).to eq([ "UNEWID" ])
  end

  it "keeps the invite row when a removal fails, so the next sync retries" do
    old = staff("ops", event: long_ended_event)
    SlackChannelInvite.create!(user: old, channel_id: "CORG", slack_user_id: old.verified_slack_id)
    allow(slack_service).to receive(:remove_from_channel).and_raise(SlackService::Error, "restricted_action")

    described_class.perform_now

    expect(SlackChannelInvite.exists?(user: old)).to be(true)
    expect(Setting.org_support_slack_last_sync).to include("removed" => 0, "failed" => 1)
  end

  it "waits out Slack's rate limit and retries the same person" do
    member = staff("event_admin")
    calls = 0
    allow(slack_service).to receive(:invite_to_channel) do
      calls += 1
      raise SlackService::RateLimited.new(3) if calls == 1

      { success: true }
    end

    described_class.perform_now

    expect(calls).to eq(2)
    expect(SlackChannelInvite.exists?(user: member)).to be(true)
    expect(Setting.org_support_slack_last_sync).to include("added" => 1, "failed" => 0)
  end

  it "gives up on someone after repeated rate limits and moves on" do
    staff("event_admin")
    allow(slack_service).to receive(:invite_to_channel).and_raise(SlackService::RateLimited.new(1))

    described_class.perform_now

    expect(slack_service).to have_received(:invite_to_channel)
      .exactly(SyncOrgSupportSlackChannelJob::MAX_RATE_LIMIT_WAITS + 1).times
    expect(Setting.org_support_slack_last_sync).to include("failed" => 1)
  end

  it "counts people outside the Slack workspace separately from failures" do
    staff("ops")
    allow(slack_service).to receive(:invite_to_channel).and_raise(SlackService::NotInWorkspace, "org_user_not_in_team")

    described_class.perform_now

    expect(Setting.org_support_slack_last_sync).to include("not_in_workspace" => 1, "failed" => 0)
  end

  it "hands an orphaned invite to the eligible user already in the channel instead of removing them" do
    member = staff("event_admin")
    SlackChannelInvite.create!(user: nil, channel_id: "CORG", slack_user_id: member.verified_slack_id)
    allow(slack_service).to receive(:invite_to_channel).and_return({ success: true, already_member: true })

    described_class.perform_now

    expect(slack_service).not_to have_received(:remove_from_channel)
    expect(SlackChannelInvite.find_by(slack_user_id: member.verified_slack_id).user).to eq(member)
  end

  it "keeps the row when Slack says not_in_channel but the bot's own membership is unconfirmed" do
    old = staff("ops", event: long_ended_event)
    SlackChannelInvite.create!(user: old, channel_id: "CORG", slack_user_id: old.verified_slack_id)
    allow(slack_service).to receive(:remove_from_channel).and_return({ success: true, not_member: true })

    described_class.perform_now

    expect(SlackChannelInvite.exists?(user: old)).to be(true)
    expect(Setting.org_support_slack_last_sync).to include("removed" => 0, "failed" => 1)
  end

  it "drops the row for someone who already left, once an invite confirms the bot is in the channel" do
    staff("event_admin")
    old = staff("ops", event: long_ended_event)
    SlackChannelInvite.create!(user: old, channel_id: "CORG", slack_user_id: old.verified_slack_id)
    allow(slack_service).to receive(:remove_from_channel).and_return({ success: true, not_member: true })

    described_class.perform_now

    expect(SlackChannelInvite.exists?(user: old)).to be(false)
    expect(Setting.org_support_slack_last_sync).to include("removed" => 1)
  end

  it "only trusts the Slack ID from Hack Club Auth" do
    typed_over = staff("limited", slack_id: nil)
    typed_over.update!(slack_user_id: "UVICTIM1,UVICTIM2")

    described_class.perform_now

    expect(slack_service).not_to have_received(:invite_to_channel)
    expect(Setting.org_support_slack_last_sync).to include("no_slack" => 1)
  end

  it "does nothing without a channel configured" do
    Setting.org_support_slack_channel_id = ""
    staff("event_admin")

    described_class.perform_now

    expect(SlackService).not_to have_received(:new)
  end

  describe "when someone is given a role" do
    it "enqueues an invite for any new event role" do
      user = create(:user)

      expect {
        create(:event_role_assignment, user: user, event: upcoming_event, role: "read_only")
      }.to have_enqueued_job(described_class).with([ user.id ])
    end

    it "enqueues an invite for new series members" do
      user = create(:user)

      expect {
        create(:series_role_assignment, user: user)
      }.to have_enqueued_job(described_class).with([ user.id ])
    end

    it "enqueues an invite when someone gets any global role" do
      user = create(:user)

      expect { user.update!(global_role: "read_only") }.to have_enqueued_job(described_class).with([ user.id ])
      expect { user.update!(name: "Renamed Admin") }.not_to have_enqueued_job(described_class)
    end

    it "only syncs that user, and doesn't overwrite the last full sync" do
      target = staff("limited")
      other = staff("ops", event: long_ended_event)
      SlackChannelInvite.create!(user: other, channel_id: "CORG", slack_user_id: other.verified_slack_id)
      Setting.org_support_slack_last_sync = { "at" => 1.day.ago.iso8601, "added" => 5 }

      described_class.perform_now([ target.id ])

      expect(slack_service).to have_received(:invite_to_channel).once
      expect_invited(target)
      expect(slack_service).not_to have_received(:remove_from_channel)
      expect(Setting.org_support_slack_last_sync["added"]).to eq(5)
    end
  end
end
