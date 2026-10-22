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

  INCIDENT_LEVEL_PILLS = {
    "red" => "bg-red-100 text-red-800",
    "amber" => "bg-amber-100 text-amber-800",
    "green" => "bg-green-100 text-green-800",
    "blue" => "bg-blue-100 text-blue-800"
  }.freeze

  # Badge for an S0–S3 incident level, used for both an incident's severity
  # and a report's priority: a Cloudscape severity badge in the console, a
  # Tailwind pill elsewhere. Shows the code; the full name is the tooltip.
  # With `full: true` the name and response target follow the badge, for
  # pages that have room to explain the code.
  def incident_level_badge(key, full: false)
    level = IncidentLevel.find(key)
    return content_tag(:span, key.to_s.humanize, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-800") unless level

    badge = if console_ui?
      content_tag(:span, level.code, class: "cs-badge cs-badge-severity-#{level.console_severity}", title: level.short_label)
    else
      content_tag(:span, level.code, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{INCIDENT_LEVEL_PILLS[level.color]}", title: level.short_label)
    end
    return badge unless full

    text_class = console_ui? ? "cs-small" : "text-sm text-gray-600"
    safe_join([ badge, content_tag(:span, incident_level_text(key), class: text_class) ], " ")
  end

  def render_severity_badge(severity)
    incident_level_badge(severity)
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

  def incident_report_priority_badge(priority)
    incident_level_badge(priority)
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
