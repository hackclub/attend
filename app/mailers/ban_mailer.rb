class BanMailer < ApplicationMailer
  layout false

  # Sent after each nightly UCAT sync when anyone on the ban list is still
  # enrolled in an event that hasn't ended. Recipients come from config, not
  # code, so the repo carries no personal addresses.
  def self.alert_recipients
    (ENV["BAN_ALERT_RECIPIENTS"].presence || Rails.application.credentials.dig(:ucat, :alert_recipients).presence).to_s
      .split(",").map(&:strip).reject(&:blank?)
  end

  def upcoming_enrollments(participant_events:, recipients: self.class.alert_recipients)
    @by_participant = participant_events
      .sort_by { |pe| [ pe.participant.full_name.downcase, pe.event.starts_at || Time.current ] }
      .group_by(&:participant)
    @host = ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "attend.hackclub.com" }
    @protocol = Rails.env.local? ? "http" : "https"
    @bans_url = Rails.application.routes.url_helpers.admin_bans_url(host: @host, protocol: @protocol)

    count = @by_participant.size
    mail(
      to: recipients,
      subject: "#{count} banned #{'person'.pluralize(count)} on upcoming events"
    )
  end

  private

  def participant_url(participant_event)
    Rails.application.routes.url_helpers.admin_event_participant_url(
      participant_event.event, participant_event.participant, host: @host, protocol: @protocol
    )
  end
  helper_method :participant_url
end
