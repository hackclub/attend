class EventStaffMailer < ApplicationMailer
  # Sent when someone is given a staff role on an event, so they know they have
  # access, what the role lets them do, and where to sign in.
  def added_to_event(assignment:, added_by: nil)
    @assignment = assignment
    @user = assignment.user
    @event = assignment.event
    @emailable = @user
    @added_by = added_by

    details = EventRoleAssignment::ROLE_DETAILS[@assignment.role] || {}
    @role_label = details[:label] || @assignment.role.humanize
    @role_summary = details[:summary]
    @role_can = Array(details[:can])
    @role_cannot = Array(details[:cannot])

    @first_name = @user.name.presence&.split&.first || @user.email.split("@").first
    @event_name = @event.name
    @dashboard_url = Rails.application.routes.url_helpers.admin_event_dashboard_url(
      @event,
      host: default_host,
      protocol: default_protocol
    )

    mail(
      to: @user.email,
      subject: "You've been added to #{@event_name} on Attend",
      reply_to: @added_by&.email || "attend@hackclub.com"
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
