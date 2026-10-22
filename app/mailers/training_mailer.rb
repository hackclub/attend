class TrainingMailer < ApplicationMailer
  # Sent when someone is added to an event's volunteer roster, so they know
  # which training to complete before the event.
  def volunteer_added(volunteer:)
    @user = volunteer.user
    @event = volunteer.event
    @emailable = @user
    @added_by = volunteer.added_by
    @badges = TrainingBadge.required_for("volunteer").ordered.to_a
    @first_name = @user.name.presence&.split&.first || @user.email.split("@").first
    @training_url = Rails.application.routes.url_helpers.training_url(host: default_host, protocol: default_protocol)

    mail(
      to: @user.email,
      subject: "You're volunteering at #{@event.name}",
      reply_to: @added_by&.email || "attend@hackclub.com"
    )
  end

  # Sent when someone is invited by hand to an invite-only course.
  def course_invitation(invitation:)
    @user = invitation.user
    @course = invitation.course
    @emailable = @user
    @invited_by = invitation.invited_by
    @first_name = @user.name.presence&.split&.first || @user.email.split("@").first
    @course_url = Rails.application.routes.url_helpers.training_course_url(@course, host: default_host, protocol: default_protocol)

    mail(
      to: @user.email,
      subject: "You've been invited to #{@course.title}",
      reply_to: @invited_by&.email || "attend@hackclub.com"
    )
  end

  # Tells the Hack Club Safety Team a declaration needs reviewing. Says who
  # and what only behind the link, where it's audit-logged.
  def disclosure_review_needed(disclosure:)
    @disclosure = disclosure
    @course_title = disclosure.course&.title
    @review_url = Rails.application.routes.url_helpers.admin_training_disclosure_url(disclosure, host: default_host, protocol: default_protocol)

    mail(to: TrainingDisclosure::SAFETY_TEAM_EMAIL, subject: "A training declaration needs review")
  end

  private

  def default_host
    ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "attend.hackclub.com" }
  end

  def default_protocol
    Rails.env.local? ? "http" : "https"
  end
end
