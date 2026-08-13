module Admin::DashboardHelper
  def severity_badge_class(severity)
    case severity
    when "critical"
      "bg-red-600 text-white"
    when "high"
      "bg-red-100 text-red-800"
    when "medium"
      "bg-amber-100 text-amber-800"
    when "low"
      "bg-green-100 text-green-800"
    else
      "bg-gray-100 text-gray-800"
    end
  end

  # The single phase pill an event row shows, as [label, badge classes].
  # An event with no dates used to fall through to "Active", which read as
  # "happening now" on a row that was really an unscheduled draft.
  def event_phase_badge(event)
    if event.completed?
      [ "Past", "bg-gray-100 text-gray-500" ]
    elsif event.starts_at.nil?
      [ "Draft", "bg-gray-100 text-gray-500" ]
    elsif event.starts_at > Time.current
      [ "Upcoming", "bg-blue-50 text-blue-700" ]
    else
      [ "Active", "bg-green-50 text-green-700" ]
    end
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
