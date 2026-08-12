class UmReviewMailer < ApplicationMailer
  REVIEWER_EMAIL = "leo@hackclub.com".freeze

  def review_request(participant_event:)
    @participant_event = participant_event
    @participant = participant_event.participant
    @event = participant_event.event
    @emailable = @participant

    @review_url = Rails.application.routes.url_helpers.travel_admin_event_participant_url(
      @event, @participant_event,
      host: default_host,
      protocol: default_protocol
    )

    mail(
      to: REVIEWER_EMAIL,
      subject: "Review a new UM flight status — #{@participant.display_name} (#{@event.name})"
    )
  end

  private

  def default_host
    ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "localhost:3000" }
  end

  def default_protocol
    Rails.env.production? ? "https" : "http"
  end
end
