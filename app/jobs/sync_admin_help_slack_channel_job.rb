# Invites event admins to the Slack channel where they ask questions about
# Attend (see Setting.admin_help_slack_channel_id). Runs for a single user when
# they're handed a staff role, and for everyone from the global settings page.
class SyncAdminHelpSlackChannelJob < ApplicationJob
  queue_as :default

  # Slack conversations.invite is Tier 3 (~50 req/min) — pause between calls.
  INVITE_PAUSE = 0.1

  # With no user_ids, syncs every eligible user and records the counts so the
  # settings page can show how the last full sync went.
  def perform(user_ids = nil)
    channel_id = Setting.admin_help_slack_channel_id
    return if channel_id.blank?

    users = User.admin_help_channel_members
    users = users.where(id: user_ids) if user_ids

    slack_service = SlackService.new
    counts = { "added" => 0, "already_member" => 0, "failed" => 0, "no_slack" => 0 }

    users.find_each do |user|
      slack_id = user.slack_id
      if slack_id.blank?
        counts["no_slack"] += 1
        next
      end

      begin
        result = slack_service.invite_to_channel(channel_id: channel_id, user_id: slack_id)
        counts[result[:already_member] ? "already_member" : "added"] += 1
      rescue SlackService::Error => e
        Rails.logger.error("[SyncAdminHelpSlackChannel] Failed to add #{slack_id}: #{e.message}")
        counts["failed"] += 1
      end

      sleep INVITE_PAUSE
    end

    Setting.admin_help_slack_last_sync = counts.merge("at" => Time.current.iso8601) if user_ids.nil?
  end
end
