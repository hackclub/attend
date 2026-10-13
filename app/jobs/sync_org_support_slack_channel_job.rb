# Keeps the org support Slack channel (Setting.org_support_slack_channel_id) in
# step with User.org_support_channel_members: invites every kind of admin while
# their events are on, and removes them once the last one is more than
# Event::ORG_SUPPORT_GRACE past its end. Only people Attend invited (a
# SlackChannelInvite row) are ever removed. Runs for a single user when they're
# handed a role, and for everyone daily and from the global settings page.
class SyncOrgSupportSlackChannelJob < ApplicationJob
  queue_as :default

  # conversations.invite and .kick are Tier 3 (~50 req/min) — pause between calls.
  SLACK_PAUSE = 0.1

  # With no user_ids, syncs everyone and records the counts so the settings
  # page can show how the last full sync went.
  def perform(user_ids = nil)
    channel_id = Setting.org_support_slack_channel_id
    return if channel_id.blank?

    @slack_service = SlackService.new
    @channel_id = channel_id
    @counts = { "added" => 0, "already_member" => 0, "removed" => 0, "failed" => 0, "no_slack" => 0 }

    members = User.org_support_channel_members
    invite_all(user_ids ? members.where(id: user_ids) : members)

    stale = SlackChannelInvite.where(channel_id: channel_id).where.not(user_id: members.select(:id))
    remove_all(user_ids ? stale.where(user_id: user_ids) : stale)

    Setting.org_support_slack_last_sync = @counts.merge("at" => Time.current.iso8601) if user_ids.nil?
  end

  private

  def invite_all(users)
    users.find_each do |user|
      slack_id = user.verified_slack_id
      if slack_id.blank?
        @counts["no_slack"] += 1
        next
      end

      begin
        result = @slack_service.invite_to_channel(channel_id: @channel_id, user_id: slack_id)
        if result[:already_member]
          @counts["already_member"] += 1
        else
          record_invite(user, slack_id)
          @counts["added"] += 1
        end
      rescue SlackService::Error => e
        Rails.logger.error("[SyncOrgSupportSlackChannel] Failed to add #{slack_id}: #{e.message}")
        @counts["failed"] += 1
      end

      sleep SLACK_PAUSE
    end
  end

  def remove_all(invites)
    invites.find_each do |invite|
      @slack_service.remove_from_channel(channel_id: @channel_id, user_id: invite.slack_user_id)
      invite.destroy!
      @counts["removed"] += 1
    rescue SlackService::Error => e
      Rails.logger.error("[SyncOrgSupportSlackChannel] Failed to remove #{invite.slack_user_id}: #{e.message}")
      @counts["failed"] += 1
    ensure
      sleep SLACK_PAUSE
    end
  end

  def record_invite(user, slack_id)
    invite = SlackChannelInvite.find_or_initialize_by(user: user, channel_id: @channel_id)
    invite.update!(slack_user_id: slack_id)
  rescue ActiveRecord::RecordNotUnique
    retry
  end
end
