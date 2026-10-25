class RegistrationCorrectionNotifications
  DIRECT_ROLES = {
    "contact" => %w[event_admin ops],
    "health" => %w[event_admin ops safeguarding_lead],
    "emergency" => %w[event_admin ops]
  }.freeze

  REQUEST_ROLES = {
    "event_admin" => %w[event_admin],
    "operations" => %w[event_admin ops],
    "safeguarding" => %w[event_admin safeguarding_lead]
  }.freeze

  def self.direct_update(participant_event, section:)
    enqueue(participant_event, section: section, roles: DIRECT_ROLES.fetch(section.to_s))
  end

  def self.change_request(change_request)
    enqueue(
      change_request.participant_event,
      section: change_request.kind,
      roles: REQUEST_ROLES.fetch(change_request.staff_audience)
    )
  end

  def self.enqueue(participant_event, section:, roles:)
    event = participant_event.event
    direct_users = event.event_role_assignments
      .where(role: roles)
      .includes(:user)
      .map(&:user)
    series_users = if event.event_series_id.present?
      User.joins(:series_role_assignments)
        .where(series_role_assignments: { event_series_id: event.event_series_id })
        .distinct
    else
      User.none
    end

    (direct_users + series_users.to_a).uniq
      .each do |recipient|
        RegistrationCorrectionMailer.staff_notification(
          recipient: recipient,
          participant_event: participant_event,
          section: section.to_s
        ).deliver_later
      end
  end

  private_class_method :enqueue
end
