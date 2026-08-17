class AirtableMailer < ApplicationMailer
  # Sent when the scheduled sync pauses an event's Airtable integration after a
  # failure. It goes to whoever last saved the credentials because they're the
  # only person who can fix them, and because a paused sync is otherwise
  # invisible — Airtable keeps showing the last good snapshot indefinitely.
  def sync_paused(event:, recipient:, error_message:)
    @event = event
    @user = recipient
    @emailable = recipient
    @error_message = error_message
    @paused_at = event.airtable_sync_paused_at
    @last_synced_at = event.airtable_synced_at
    @first_name = recipient.name.presence&.split&.first || recipient.email.split("@").first
    @integrations_url = Rails.application.routes.url_helpers.admin_event_integrations_url(
      @event,
      host: default_host,
      protocol: default_protocol
    )

    mail(
      to: recipient.email,
      subject: "Airtable sync paused for #{@event.name}",
      reply_to: "attend@hackclub.com"
    )
  end

  private

  def default_host
    ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "attend.hackclub.com" }
  end

  def default_protocol
    Rails.env.local? ? "http" : "https"
  end
end
