# Shared plumbing for the jobs that keep a Slack channel in step with a list
# of people. conversations.invite is Tier 3 (~50 req/min), so inviting
# everyone on every run — mostly people already there — is what made a full
# sync take minutes. Instead, list the channel once (Tier 4, 1,000 IDs a page)
# and only spend invites on people who aren't in it.
module SlackChannelSync
  extend ActiveSupport::Concern

  private

  # The channel's member IDs, or nil when Slack won't list them (a missing
  # scope, the bot outside a private channel). nil means "don't know", and the
  # caller invites everyone as before.
  def prefetch_channel_members(slack_service, channel_id)
    slack_service.channel_member_ids(channel_id: channel_id)
  rescue SlackService::Error => e
    Rails.logger.warn("[#{self.class.name}] Couldn't list #{channel_id} members, inviting everyone: #{e.message}")
    nil
  end

  # Keeps Slack calls at least `pause` seconds apart without sleeping after
  # the last one, so a single-user run isn't padded by a pause it never needs.
  def throttle_slack(pause)
    if @last_slack_call_at
      wait = pause - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_slack_call_at)
      sleep wait if wait.positive?
    end
    yield
  ensure
    @last_slack_call_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
