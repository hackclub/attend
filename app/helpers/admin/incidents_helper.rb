module Admin::IncidentsHelper
  INCIDENT_STATUS_TYPES = {
    "open" => :warning,
    "in_review" => :in_progress,
    "closed" => :success,
    "resolved" => :success
  }.freeze

  INCIDENT_CATEGORY_COLORS = {
    "safeguarding" => "red",
    "medical" => "blue",
    "behavior" => "yellow"
  }.freeze

  INCIDENT_REPORT_PRIORITY_SEVERITIES = {
    "emergency" => "critical",
    "elevated" => "medium",
    "standard" => "neutral"
  }.freeze

  # Severity badge for an incident's severity enum: a Cloudscape severity
  # badge in the console, the original Tailwind pill elsewhere.
  def render_severity_badge(severity)
    return cs_severity_badge(severity) if console_ui?

    colors = {
      "low" => "bg-green-100 text-green-800",
      "medium" => "bg-yellow-100 text-yellow-800",
      "high" => "bg-orange-100 text-orange-800",
      "critical" => "bg-red-100 text-red-800"
    }
    color_class = colors[severity] || "bg-gray-100 text-gray-800"

    content_tag(:span, severity.humanize, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{color_class}")
  end

  # Cloudscape status indicator for incident and incident-report statuses.
  def incident_status(status)
    cs_status(INCIDENT_STATUS_TYPES.fetch(status.to_s, :info), status.to_s.humanize)
  end

  # Icon for a cs-steps timeline entry, coloured like the matching status.
  def incident_step_icon(type)
    content_tag(:span, cs_status_icon(type), class: "cs-step-icon cs-status-#{type.to_s.dasherize}")
  end

  # Step icon for a comment: a status change takes that status's colour.
  def incident_comment_step_icon(new_status)
    incident_step_icon(new_status.present? ? INCIDENT_STATUS_TYPES.fetch(new_status.to_s, :info) : :info)
  end

  def render_category_badge(category)
    return cs_badge(category.to_s.humanize, INCIDENT_CATEGORY_COLORS[category.to_s]) if console_ui?

    colors = {
      "safeguarding" => "bg-purple-100 text-purple-800",
      "medical" => "bg-pink-100 text-pink-800",
      "behavior" => "bg-indigo-100 text-indigo-800",
      "other" => "bg-gray-100 text-gray-800"
    }
    color_class = colors[category] || "bg-gray-100 text-gray-800"

    content_tag(:span, category.humanize, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{color_class}")
  end

  # Incident-report priorities read as severities: emergency is the critical end.
  def incident_report_priority_badge(priority)
    label = IncidentReport::PRIORITIES[priority]&.split(" – ")&.first || priority.to_s.humanize
    cs_severity_badge(INCIDENT_REPORT_PRIORITY_SEVERITIES.fetch(priority.to_s, "neutral"), label)
  end

  # Tailwind pill, identical to main. Used by the original incident views and
  # for participant statuses in participants/_participant_card (also rendered
  # on the support ticket page outside the console). Console incident views
  # use incident_status instead.
  def render_status_badge(status)
    colors = {
      "open" => "bg-blue-100 text-blue-800",
      "in_review" => "bg-yellow-100 text-yellow-800",
      "closed" => "bg-gray-100 text-gray-800"
    }
    color_class = colors[status] || "bg-gray-100 text-gray-800"

    content_tag(:span, status.humanize.titleize, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{color_class}")
  end
end
