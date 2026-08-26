module Admin::ParticipantsHelper
  DISPLAY_STATUS_STYLES = {
    "Complete" => "bg-green-50 text-green-700",
    "Awaiting Participant" => "bg-blue-50 text-blue-700",
    "Awaiting Parent" => "bg-amber-50 text-amber-700",
    "Withdrawn" => "bg-red-50 text-red-700",
    "Rejected" => "bg-red-50 text-red-700"
  }.freeze

  BLOCKING_STEP_LABELS = {
    "profile" => "Needs profile",
    "travel" => "Needs travel",
    "accommodation" => "Needs accommodation",
    "health" => "Needs health info",
    "code_of_conduct" => "Needs code of conduct",
    "guardian_details" => "Needs guardian details",
    "guardian_portal" => "Awaiting guardian portal",
    "emergency_contacts" => "Needs emergency contacts",
    "waiver" => "Awaiting waiver signature",
    "freedom_waiver" => "Awaiting freedom waiver",
    "custom_documents" => "Awaiting documents"
  }.freeze

  # Optional documents only apply to participants who opted in, so "not
  # added" is a legitimate end state rather than something to chase.
  OPTIONAL_DOCUMENT_STATE_LABELS = {
    signed: "Signed",
    awaiting: "Awaiting signature",
    withdrawn: "Removed",
    not_added: "Not added"
  }.freeze

  OPTIONAL_DOCUMENT_STATE_STYLES = {
    signed: "bg-green-100 text-green-700",
    awaiting: "bg-yellow-100 text-yellow-700",
    withdrawn: "bg-gray-100 text-gray-600",
    not_added: "text-gray-400"
  }.freeze

  def optional_document_state_label(state)
    OPTIONAL_DOCUMENT_STATE_LABELS.fetch(state, state.to_s.humanize)
  end

  def render_optional_document_badge(participant_event, custom_document)
    state = participant_event.optional_document_state(custom_document)
    label = optional_document_state_label(state)
    style = OPTIONAL_DOCUMENT_STATE_STYLES.fetch(state, "bg-gray-100 text-gray-800")

    return content_tag(:span, label, class: style) if state == :not_added

    content_tag(:span, label, class: "inline-flex items-center px-1.5 py-0.5 rounded text-xs #{style}")
  end

  # The group dropdown shows the current grouping back to the admin; a
  # compound optional-document key would otherwise titleize into a raw UUID.
  def group_by_label(group_by, optional_documents)
    doc = optional_documents.find { |d| group_by == "optional_document:#{d.id}" }
    doc ? doc.name : group_by.titleize
  end

  def render_display_status_badge(participant_event)
    ds = participant_event.display_status
    css_class = DISPLAY_STATUS_STYLES[ds] || "bg-gray-100 text-gray-800"
    content_tag(:span, ds, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{css_class}")
  end

  def render_blocking_step_badge(participant_event)
    ds = participant_event.display_status
    return nil if %w[Complete Withdrawn Rejected].include?(ds)

    progress = participant_event.onboarding_progress
    blocking = progress[:blocking_step]
    return nil unless blocking

    label = BLOCKING_STEP_LABELS[blocking] || blocking.titleize
    content_tag(:span, label, class: "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-50 text-yellow-700 border border-yellow-200")
  end

  def render_sort_icon(field, current_sort, current_direction)
    return "" unless current_sort == field

    if current_direction == "asc"
      content_tag(:svg, class: "w-4 h-4 text-[#ec3750]") do
        content_tag(:path, "", "stroke-linecap": "round", "stroke-linejoin": "round", "stroke-width": "2", d: "M5 15l7-7 7 7", fill: "none", stroke: "currentColor")
      end
    else
      content_tag(:svg, class: "w-4 h-4 text-[#ec3750]") do
        content_tag(:path, "", "stroke-linecap": "round", "stroke-linejoin": "round", "stroke-width": "2", d: "M19 9l-7 7-7-7", fill: "none", stroke: "currentColor")
      end
    end
  end
end
