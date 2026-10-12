module Admin::ParticipantsHelper
  # Cloudscape status indicator type for each participant display status.
  DISPLAY_STATUS_TYPES = {
    "Complete" => :success,
    "Awaiting Participant" => :in_progress,
    "Awaiting Parent" => :pending,
    "Withdrawn" => :stopped,
    "Rejected" => :error
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

  OPTIONAL_DOCUMENT_STATE_TYPES = {
    signed: :success,
    awaiting: :pending,
    withdrawn: :stopped
  }.freeze

  def optional_document_state_label(state)
    OPTIONAL_DOCUMENT_STATE_LABELS.fetch(state, state.to_s.humanize)
  end

  def render_optional_document_badge(participant_event, custom_document)
    state = participant_event.optional_document_state(custom_document)
    label = optional_document_state_label(state)

    return content_tag(:span, label, class: "cs-muted") if state == :not_added

    cs_status(OPTIONAL_DOCUMENT_STATE_TYPES.fetch(state, :info), label)
  end

  # The group dropdown shows the current grouping back to the admin; a
  # compound optional-document key would otherwise titleize into a raw UUID.
  def group_by_label(group_by, optional_documents)
    doc = optional_documents.find { |d| group_by == "optional_document:#{d.id}" }
    doc ? doc.name : group_by.titleize
  end

  def render_display_status_badge(participant_event)
    ds = participant_event.display_status
    cs_status(DISPLAY_STATUS_TYPES.fetch(ds, :info), ds)
  end

  def render_blocking_step_badge(participant_event)
    ds = participant_event.display_status
    return nil if %w[Complete Withdrawn Rejected].include?(ds)

    progress = participant_event.onboarding_progress
    blocking = progress[:blocking_step]
    return nil unless blocking

    label = BLOCKING_STEP_LABELS[blocking] || blocking.titleize
    cs_badge(label, "yellow")
  end

  # Placeholder for a contact detail the current role isn't allowed to see (see
  # EventRoleAssignment::PII_RESTRICTED_ROLES). Every surface hides it the same
  # way, and the title says why so it doesn't read as missing data.
  def contact_hidden_placeholder(label = "Hidden")
    content_tag(:span, label, class: "italic text-gray-400",
      title: "Phone numbers and guardian contact details are hidden for your role")
  end

  # A participant's name, or a muted label for someone who signed in but hasn't
  # given us one yet (see Participant#name_pending?). legal: shows the legal
  # name rather than the preferred one.
  def participant_name(participant, legal: false)
    return pending_name_label if participant.name_pending? && (legal || participant.preferred_name.blank?)

    legal ? participant.full_name : participant.display_name
  end

  # One half of a legal name for table columns, with the onboarding
  # placeholder shown as the pending label (or a dash, for the second column
  # so a pending row doesn't say it twice).
  def legal_name_part(value, dash: false)
    return value unless Participant.name_placeholder?(value)

    dash ? content_tag(:span, "—", class: "cs-muted") : pending_name_label
  end

  def pending_name_label
    content_tag(:span, Participant::PENDING_NAME_LABEL, class: "italic font-normal text-gray-400",
      title: "Signed in, but hasn't filled in their name yet")
  end

  # Cloudscape sort caret for a sortable column header (inside .cs-sort). An
  # unsorted column shows a muted two-way caret; the sorted one points the
  # current direction.
  def render_sort_icon(field, current_sort, current_direction)
    path = if current_sort != field
      "M4 6l4-4 4 4M4 10l4 4 4-4"
    elsif current_direction == "asc"
      "M4 10l4-4 4 4"
    else
      "M4 6l4 4 4-4"
    end
    content_tag(:svg, tag.path(d: path), viewBox: "0 0 16 16", fill: "none", stroke: "currentColor",
      "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true")
  end

  # aria-sort value for a sortable column header.
  def sort_aria(field, current_sort, current_direction)
    return nil unless current_sort == field

    current_direction == "asc" ? "ascending" : "descending"
  end
end
