class SendIncidentUpdateToSlackJob < ApplicationJob
  queue_as :default

  CONDUCT_CHANNEL_ID = Rails.env.production? ? "G01DBHPLK25" : "C0834H301MF"

  TEXT_FIELDS = %w[summary details actions_taken location].freeze
  SIMPLE_FIELDS = %w[category severity status].freeze

  def perform(incident_id, user_id, changes)
    incident = Incident.find(incident_id)
    user = User.find(user_id)

    return unless incident.slack_message_ts.present?
    return if changes.empty?

    text = build_update_text(user, changes)

    SlackService.new.send_to_channel(
      channel_id: CONDUCT_CHANNEL_ID,
      text: text,
      thread_ts: incident.slack_message_ts
    )
  end

  private

  def build_update_text(user, changes)
    slack_id = user.oidc_claims&.dig("slack_id") || user.participant&.slack_user_id
    user_mention = slack_id.present? ? "<@#{slack_id}>" : user.display_name_or_fallback

    change_descriptions = []

    changes.each do |field, (old_value, new_value)|
      next if field == "updated_at"
      next if field == "visible_to_roles"

      if SIMPLE_FIELDS.include?(field)
        change_descriptions << format_simple_change(field, old_value, new_value)
      elsif TEXT_FIELDS.include?(field)
        change_descriptions << format_text_change(field, old_value, new_value)
      end
    end

    return nil if change_descriptions.empty?

    "📝 #{user_mention} updated the incident:\n\n#{change_descriptions.join("\n\n")}"
  end

  def format_simple_change(field, old_value, new_value)
    field_name = field.humanize.titleize
    old_display = old_value.presence&.humanize&.titleize || "empty"
    new_display = new_value.presence&.humanize&.titleize || "empty"
    "*#{field_name}:* #{old_display} → #{new_display}"
  end

  def format_text_change(field, old_value, new_value)
    field_name = field.humanize.titleize
    old_text = old_value.to_s.strip
    new_text = new_value.to_s.strip

    if old_text.blank? && new_text.present?
      "*#{field_name}:* _(was empty)_ → Added:\n> #{truncate_for_slack(new_text)}"
    elsif old_text.present? && new_text.blank?
      "*#{field_name}:* Removed _(was: #{truncate_for_slack(old_text)})_"
    else
      diff = generate_friendly_diff(old_text, new_text)
      "*#{field_name}:* Updated\n#{diff}"
    end
  end

  def generate_friendly_diff(old_text, new_text)
    old_lines = old_text.split("\n")
    new_lines = new_text.split("\n")

    if old_lines.length == 1 && new_lines.length == 1 && old_text.length < 100 && new_text.length < 100
      return "> ~#{truncate_for_slack(old_text)}~\n> #{truncate_for_slack(new_text)}"
    end

    removed = (old_lines - new_lines).first(3)
    added = (new_lines - old_lines).first(3)

    parts = []
    parts << removed.map { |l| "> - ~#{truncate_for_slack(l)}~" }.join("\n") if removed.any?
    parts << added.map { |l| "> + #{truncate_for_slack(l)}" }.join("\n") if added.any?

    parts.any? ? parts.join("\n") : "> _(content modified)_"
  end

  def truncate_for_slack(text, max_length = 150)
    return text if text.length <= max_length

    "#{text[0, max_length - 3]}..."
  end
end
