# Keeps the org support Slack channel (Setting.org_support_slack_channel_id) in
# step with User.org_support_channel_members: invites every kind of admin while
# their events are on, and removes them once the last one is more than
# Event::ORG_SUPPORT_GRACE past its end. Only people Attend invited (a
# SlackChannelInvite row) are ever removed. Runs for a single user when they're
# handed a role, and for everyone daily and from the global settings page.
class SyncOrgSupportSlackChannelJob < ApplicationJob
  queue_as :default

  # conversations.invite and .kick are Tier 3 (~50 req/min) — pause between
  # calls, and when Slack still says slow down, wait as long as it asks and
  # retry the same person rather than counting them as failed.
  SLACK_PAUSE = 1.2
  MAX_RATE_LIMIT_WAITS = 5

  # With no user_ids, syncs everyone and records the counts so the settings
  # page can show how the last full sync went.
  def perform(user_ids = nil)
    channel_id = Setting.org_support_slack_channel_id
    return if channel_id.blank?

    @slack_service = SlackService.new
    @channel_id = channel_id
    @counts = { "added" => 0, "already_member" => 0, "removed" => 0, "failed" => 0, "no_slack" => 0,
                "not_in_workspace" => 0 }
    # Set once Slack confirms the bot is in the channel (any invite that
    # doesn't fail), which removals need; see SlackService#remove_from_channel.
    @bot_in_channel = false

    members = User.org_support_channel_members
    invite_all(user_ids ? members.where(id: user_ids) : members)

    # Kept only while the row's user still exists, is still eligible, and
    # still has that Slack ID; a deleted user or a changed ID leaves a row
    # whose Slack account must go.
    current = members.where("users.id = slack_channel_invites.user_id")
      .where("users.verified_slack_id = slack_channel_invites.slack_user_id")
    stale = SlackChannelInvite.where(channel_id: channel_id).where(current.arel.exists.not)
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
        result = with_rate_limit_retry { @slack_service.invite_to_channel(channel_id: @channel_id, user_id: slack_id) }
        @bot_in_channel = true
        if result[:already_member]
          claim_existing_invite(user, slack_id)
          @counts["already_member"] += 1
        else
          record_invite(user, slack_id)
          @counts["added"] += 1
        end
      rescue SlackService::NotInWorkspace
        @counts["not_in_workspace"] += 1
      rescue SlackService::Error => e
        Rails.logger.error("[SyncOrgSupportSlackChannel] Failed to add #{slack_id}: #{e.message}")
        @counts["failed"] += 1
      end

      sleep SLACK_PAUSE
    end
  end

  def remove_all(invites)
    invites.find_each do |invite|
      result = with_rate_limit_retry { @slack_service.remove_from_channel(channel_id: @channel_id, user_id: invite.slack_user_id) }
      if result[:not_member] && !@bot_in_channel
        # Could just as well mean the bot isn't in the channel: keep the row
        # for a run that can tell the difference.
        Rails.logger.error("[SyncOrgSupportSlackChannel] Couldn't confirm removal of #{invite.slack_user_id}: not_in_channel")
        @counts["failed"] += 1
        next
      end

      invite.destroy!
      @counts["removed"] += 1
    rescue SlackService::Error => e
      Rails.logger.error("[SyncOrgSupportSlackChannel] Failed to remove #{invite.slack_user_id}: #{e.message}")
      @counts["failed"] += 1
    ensure
      sleep SLACK_PAUSE
    end
  end

  def with_rate_limit_retry
    waits = 0
    begin
      yield
    rescue SlackService::RateLimited => e
      raise if (waits += 1) > MAX_RATE_LIMIT_WAITS

      sleep e.retry_after
      retry
    end
  end

  # Someone already in the channel may still have a row from an earlier
  # invite under another (deleted or merged) user; point it at this eligible
  # one so the removal pass doesn't treat it as stale.
  def claim_existing_invite(user, slack_id)
    SlackChannelInvite.where(channel_id: @channel_id, slack_user_id: slack_id)
      .where("user_id IS DISTINCT FROM ?", user.id)
      .update_all(user_id: user.id, updated_at: Time.current)
  end

  def record_invite(user, slack_id)
    invite = SlackChannelInvite.find_or_initialize_by(channel_id: @channel_id, slack_user_id: slack_id)
    invite.update!(user: user)
  rescue ActiveRecord::RecordNotUnique
    retry
  end
end
