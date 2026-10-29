module VisaLettersHelper
  # The admin list's status filters, in Envoy's words.
  VISA_LETTER_FILTER_LABELS = {
    "pending" => "Pending Approval", "approved" => "Approved", "letter_sent" => "Letter Sent",
    "rejected" => "Rejected", "all" => "All Statuses"
  }.freeze

  VISA_LETTER_MODE_LABELS = {
    "off" => [ "Off", "Attend doesn't take visa letter applications for this event." ],
    "invite_only" => [ "Invited people only", "Only people your team invites to apply can ask for a letter." ],
    "open" => [ "Open form", "Anyone can apply through the public form until the deadline. Your team reviews every application." ]
  }.freeze

  # Where a participant asks for a visa letter: Attend's own form, when the
  # event issues letters here. Nil otherwise. An event's old Envoy URL
  # (visa_application_url) isn't offered: the event forms no longer show it,
  # so nobody could correct or clear it, and Envoy's host is Attend's now.
  def visa_letter_request_path_for(event)
    visas_apply_path(event.slug) if event.visa_letters_enabled?
  end

  # [status type, label] for cs_status and the legacy badges. Envoy's labels.
  def visa_letter_status(application)
    case application.status
    when "pending" then [ :pending, "Pending Approval" ]
    when "approved" then [ :in_progress, "Approved" ]
    when "letter_sent" then [ :success, "Letter Sent" ]
    when "rejected" then application.hard_rejected? ? [ :error, "Rejected" ] : [ :warning, "Rejected" ]
    end
  end

  # [portal badge modifier, label] for the applicant's own pages. Envoy's labels.
  def applicant_visa_letter_status(application)
    case application.status
    when "pending" then [ "pending", "Pending Approval" ]
    when "approved" then [ "waiting", "Approved" ]
    when "letter_sent" then [ "done", "Letter Sent" ]
    when "rejected" then [ "neutral", "Rejected" ]
    end
  end

  LEGACY_STATUS_CLASSES = {
    pending: "bg-yellow-100 text-yellow-800",
    in_progress: "bg-blue-100 text-blue-800",
    success: "bg-green-100 text-green-800",
    warning: "bg-orange-100 text-orange-800",
    error: "bg-red-100 text-red-800"
  }.freeze

  def legacy_visa_status_badge((type, label))
    tag.span(label, class: "inline-flex px-2 py-0.5 rounded-full text-xs font-medium #{LEGACY_STATUS_CLASSES.fetch(type)}")
  end
end
