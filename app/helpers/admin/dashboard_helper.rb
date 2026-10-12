module Admin::DashboardHelper
  # The single phase an event row shows, as [label, status indicator type].
  # An event with no dates used to fall through to "Active", which read as
  # "happening now" on a row that was really an unscheduled draft.
  def event_phase(event)
    if event.completed?
      [ "Past", :stopped ]
    elsif event.starts_at.nil?
      [ "Draft", :pending ]
    elsif event.starts_at > Time.current
      [ "Upcoming", :info ]
    else
      [ "Active", :success ]
    end
  end

  # Cloudscape status indicator for an event's phase.
  def event_phase_status(event)
    label, type = event_phase(event)
    cs_status(type, label)
  end

  # "Aug 13, 2026" · "Aug 13–15, 2026" · "Aug 30 – Sep 2, 2026" ·
  # "Dec 30, 2026 – Jan 2, 2027". The previous inline format always printed
  # both ends, so a one-day event read "Aug 13 - Aug 13, 2026".
  def event_date_range(starts_at, ends_at)
    start_date = starts_at&.to_date
    end_date = ends_at&.to_date

    return "Dates not set" if start_date.nil? && end_date.nil?
    return "Ends #{end_date.strftime('%b %-d, %Y')}" if start_date.nil?
    return start_date.strftime("%b %-d, %Y") if end_date.nil? || start_date == end_date

    if start_date.year != end_date.year
      "#{start_date.strftime('%b %-d, %Y')} – #{end_date.strftime('%b %-d, %Y')}"
    elsif start_date.month == end_date.month
      "#{start_date.strftime('%b %-d')}–#{end_date.strftime('%-d, %Y')}"
    else
      "#{start_date.strftime('%b %-d')} – #{end_date.strftime('%b %-d, %Y')}"
    end
  end

  # Participant totals for the events list come from one grouped COUNT loaded
  # by the controller; other pages render the same row without it.
  def event_participant_count(event)
    @event_participant_counts ? @event_participant_counts.fetch(event.id, 0) : event.participants.count
  end
end
