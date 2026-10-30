module Admin::ParticipantsHelper
  # Colours for ParticipantStatusPresenter tones: green done, amber waiting,
  # blue with staff right now, grey nothing to act on.
  STATUS_TONE_STYLES = {
    done: "bg-green-50 text-green-700",
    wait: "bg-amber-50 text-amber-700",
    live: "bg-blue-50 text-blue-700",
    idle: "bg-gray-100 text-gray-700"
  }.freeze

  STATUS_TONE_TYPES = { done: :success, wait: :pending, live: :in_progress, idle: :stopped }.freeze

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

    if console_ui?
      return content_tag(:span, label, class: "cs-muted") if state == :not_added

      return cs_status(OPTIONAL_DOCUMENT_STATE_TYPES.fetch(state, :info), label)
    end

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

  # The status cell: registration status until a scan places them, then where
  # their latest scan puts them (ParticipantStatusPresenter). The title says
  # what the word means and which scan it comes from.
  def render_display_status_badge(participant_event)
    status = ParticipantStatusPresenter.new(participant_event, now: (@participant_status_now ||= Time.current))
    time = status.scanned_at_label

    if console_ui?
      badge = cs_status(STATUS_TONE_TYPES.fetch(status.tone), status.label)
      time_tag = time && content_tag(:span, time, class: "cs-small cs-muted")
    else
      badge = content_tag(:span, status.label,
        class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{STATUS_TONE_STYLES.fetch(status.tone)}")
      time_tag = time && content_tag(:span, time, class: "text-xs text-gray-500")
    end

    content_tag(:span, safe_join([ badge, time_tag ].compact, " "),
      class: "inline-flex flex-wrap items-center gap-x-1.5", title: status.explanation)
  end

  def render_blocking_step_badge(participant_event)
    ds = participant_event.display_status
    return nil if %w[Complete Withdrawn Rejected].include?(ds)

    progress = participant_event.onboarding_progress
    blocking = progress[:blocking_step]
    return nil unless blocking

    label = BLOCKING_STEP_LABELS[blocking] || blocking.titleize
    return cs_badge(label, "yellow") if console_ui?

    content_tag(:span, label, class: "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-50 text-yellow-700 border border-yellow-200")
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

    dash ? content_tag(:span, "—", class: console_ui? ? "cs-muted" : "text-gray-400") : pending_name_label
  end

  def pending_name_label
    content_tag(:span, Participant::PENDING_NAME_LABEL, class: "italic font-normal text-gray-400",
      title: "Signed in, but hasn't filled in their name yet")
  end

  # Sort caret for a sortable column header. In the console (inside .cs-sort)
  # an unsorted column shows a muted two-way caret and the sorted one points
  # the current direction; the original UI shows a red chevron on the sorted
  # column only.
  def render_sort_icon(field, current_sort, current_direction)
    return legacy_sort_icon(field, current_sort, current_direction) unless console_ui?

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

  def legacy_sort_icon(field, current_sort, current_direction)
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

  # aria-sort value for a sortable column header.
  def sort_aria(field, current_sort, current_direction)
    return nil unless current_sort == field

    current_direction == "asc" ? "ascending" : "descending"
  end

  # Link text for each signed DocuSeal document on a consent, in DocuSeal's
  # order (links go to consent_document by index). Several documents are told
  # apart by the name DocuSeal gave each one.
  def signed_document_labels(consent, label)
    documents = consent.signed_documents
    if documents.empty?
      # Marked signed by an API sync rather than the webhook, so nothing is
      # stored yet; opening the link fetches it.
      return consent.signed? && consent.docuseal_envelope_id.present? ? [ label ] : []
    end
    return [ label ] if documents.one?

    documents.each_with_index.map { |document, i| document["name"].presence || "#{label} #{i + 1}" }
  end
end
