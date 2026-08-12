class ProcessSlackIncidentReplyJob < ApplicationJob
  queue_as :default

  def perform(channel_id:, thread_ts:, message_ts:, user_id:, text:)
    incident = Incident.find_by(slack_message_ts: thread_ts)
    return unless incident

    comment_body = text.sub(/^\?\s*/, "")
    return if comment_body.blank?

    slack_display_name, slack_avatar_url = fetch_slack_user_info(user_id)

    user = find_or_create_system_user

    incident.comments.create!(
      body: comment_body,
      user: user,
      source: "slack",
      slack_message_ts: message_ts,
      slack_channel_id: channel_id,
      slack_user_id: user_id,
      slack_display_name: slack_display_name,
      slack_avatar_url: slack_avatar_url
    )
  end

  private

  def fetch_slack_user_info(user_id)
    slack_service = SlackService.new
    slack_user_info = slack_service.get_user_info(user_id: user_id)
    profile = slack_user_info["profile"]

    display_name = profile["display_name"].presence ||
                   profile["real_name"].presence ||
                   slack_user_info["name"]
    avatar_url = profile["image_72"].presence || profile["image_48"]

    [ display_name, avatar_url ]
  rescue SlackService::Error => e
    Rails.logger.warn("Could not fetch Slack user info for #{user_id}: #{e.message}")
    [ nil, nil ]
  end

  def find_or_create_system_user
    User.find_or_create_by!(email: "firehouse@hackclub.com") do |user|
      user.global_role = :no_role
    end
  end
end
