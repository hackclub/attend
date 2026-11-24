class EventCreationInviteMailer < ApplicationMailer
  # Sent when a global admin invites someone to create an event. The link's
  # token is issued here, as the email is built, so it exists nowhere else.
  def invite(invite)
    @invite = invite
    @invited_by = invite.invited_by
    @series = invite.event_series
    @url = Rails.application.routes.url_helpers.event_creation_invite_url(
      invite.issue_token!,
      host: default_host,
      protocol: default_protocol
    )

    mail(
      to: invite.email,
      subject: "Set up your event on Attend",
      reply_to: @invited_by&.email || "attend@hackclub.com"
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
