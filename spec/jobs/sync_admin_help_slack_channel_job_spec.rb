require "rails_helper"

RSpec.describe SyncAdminHelpSlackChannelJob, type: :job do
  include ActiveJob::TestHelper

  let(:slack_service) { instance_double(SlackService) }
  let(:upcoming_event) { create(:event) }
  let(:past_event) { create(:event, starts_at: 3.weeks.ago, ends_at: 2.weeks.ago) }

  before do
    Setting.admin_help_slack_channel_id = "CHELP"
    allow(SlackService).to receive(:new).and_return(slack_service)
    allow(slack_service).to receive(:invite_to_channel).and_return({ success: true })
    stub_const("SyncAdminHelpSlackChannelJob::INVITE_PAUSE", 0)
  end

  def slack_user(slack_id = "U#{SecureRandom.hex(3).upcase}", **attrs)
    create(:user, oidc_claims: slack_id ? { "slack_id" => slack_id } : {}, **attrs)
  end

  def staff(role, event: upcoming_event, slack_id: "U#{SecureRandom.hex(3).upcase}")
    user = slack_user(slack_id)
    create(:event_role_assignment, user: user, event: event, role: role)
    user
  end

  it "invites event admins, ops, and safeguarding leads on events that haven't ended" do
    invited = %w[event_admin ops safeguarding_lead].map { |role| staff(role) }

    described_class.perform_now

    invited.each do |user|
      expect(slack_service).to have_received(:invite_to_channel).with(channel_id: "CHELP", user_id: user.verified_slack_id)
    end
  end

  it "skips limited and read-only staff, past events, and people without Slack" do
    limited = staff("limited")
    read_only = staff("read_only")
    past = staff("event_admin", event: past_event)
    staff("event_admin", slack_id: nil)

    described_class.perform_now

    expect(slack_service).not_to have_received(:invite_to_channel)
    [ limited, read_only, past ].each { |user| expect(User.admin_help_channel_members).not_to include(user) }
    expect(Setting.admin_help_slack_last_sync).to include("added" => 0, "no_slack" => 1)
  end

  it "includes global admins but not global read-only users" do
    admin = slack_user("UADMIN", global_role: "global_admin")
    viewer = slack_user("UVIEWER", global_role: "read_only")

    described_class.perform_now

    expect(slack_service).to have_received(:invite_to_channel).with(channel_id: "CHELP", user_id: admin.verified_slack_id)
    expect(slack_service).not_to have_received(:invite_to_channel).with(channel_id: "CHELP", user_id: viewer.verified_slack_id)
  end

  it "includes series members with an event still to come" do
    series = create(:event_series)
    create(:event, event_series: series)
    member = slack_user("USERIES")
    create(:series_role_assignment, user: member, event_series: series)

    described_class.perform_now

    expect(slack_service).to have_received(:invite_to_channel).with(channel_id: "CHELP", user_id: "USERIES")
  end

  it "records counts from a full sync" do
    added = staff("event_admin")
    member = staff("ops")
    failing = staff("safeguarding_lead")
    allow(slack_service).to receive(:invite_to_channel).with(channel_id: "CHELP", user_id: member.verified_slack_id)
      .and_return({ success: true, already_member: true })
    allow(slack_service).to receive(:invite_to_channel).with(channel_id: "CHELP", user_id: failing.verified_slack_id)
      .and_raise(SlackService::Error, "nope")

    described_class.perform_now

    expect(slack_service).to have_received(:invite_to_channel).with(channel_id: "CHELP", user_id: added.verified_slack_id)
    expect(Setting.admin_help_slack_last_sync).to include("added" => 1, "already_member" => 1, "failed" => 1, "no_slack" => 0)
  end

  it "only trusts the Slack ID from Hack Club Auth, never the profile override" do
    typed_over = staff("event_admin", slack_id: nil)
    typed_over.update!(slack_user_id: "UVICTIM1,UVICTIM2")
    malformed = staff("ops", slack_id: "U1,U2")

    described_class.perform_now

    expect(slack_service).not_to have_received(:invite_to_channel)
    expect(malformed.verified_slack_id).to be_nil
    expect(Setting.admin_help_slack_last_sync).to include("no_slack" => 2)
  end

  it "does nothing without a channel configured" do
    Setting.admin_help_slack_channel_id = ""
    staff("event_admin")

    described_class.perform_now

    expect(SlackService).not_to have_received(:new)
  end

  describe "when someone is given a role" do
    it "enqueues an invite for eligible roles and role changes" do
      user = create(:user)

      expect {
        create(:event_role_assignment, user: user, event: upcoming_event, role: "ops")
      }.to have_enqueued_job(described_class).with([ user.id ])

      assignment = create(:event_role_assignment, event: upcoming_event, role: "limited")
      expect {
        assignment.update!(role: "event_admin")
      }.to have_enqueued_job(described_class).with([ assignment.user_id ])
    end

    it "doesn't enqueue for limited or read-only roles" do
      expect {
        create(:event_role_assignment, event: upcoming_event, role: "limited")
        create(:event_role_assignment, event: upcoming_event, role: "read_only")
      }.not_to have_enqueued_job(described_class)
    end

    it "enqueues an invite when someone becomes a global admin" do
      user = create(:user)

      expect {
        user.update!(global_role: "global_admin")
      }.to have_enqueued_job(described_class).with([ user.id ])
      expect {
        user.update!(name: "Renamed Admin")
      }.not_to have_enqueued_job(described_class)
    end

    it "enqueues an invite for new series members" do
      user = create(:user)

      expect {
        create(:series_role_assignment, user: user)
      }.to have_enqueued_job(described_class).with([ user.id ])
    end

    it "only invites that user, and doesn't overwrite the last full sync" do
      target = staff("event_admin")
      staff("ops")
      Setting.admin_help_slack_last_sync = { "at" => 1.day.ago.iso8601, "added" => 5 }

      described_class.perform_now([ target.id ])

      expect(slack_service).to have_received(:invite_to_channel).once
      expect(slack_service).to have_received(:invite_to_channel).with(channel_id: "CHELP", user_id: target.verified_slack_id)
      expect(Setting.admin_help_slack_last_sync["added"]).to eq(5)
    end
  end
end
