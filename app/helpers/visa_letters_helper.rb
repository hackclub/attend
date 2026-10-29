module VisaLettersHelper
  VISA_LETTER_MODE_LABELS = {
    "off" => [ "Off", "Attend doesn't take visa letter applications for this event." ],
    "invite_only" => [ "Invited people only", "Only people your team invites to apply can ask for a letter." ],
    "open" => [ "Open form", "Anyone can apply through the public form until the deadline. Your team reviews every application." ]
  }.freeze

  # [status type, label] for cs_status and the legacy badges.
  def visa_letter_status(application)
    case application.status
    when "pending" then [ :pending, "Awaiting review" ]
    when "approved" then [ :in_progress, "Generating letter" ]
    when "letter_sent" then [ :success, "Letter sent" ]
    when "rejected" then application.hard_rejected? ? [ :error, "Rejected" ] : [ :warning, "Rejected, can reapply" ]
    end
  end

  # Nil until there's a letter for the embassy to decide on.
  def visa_outcome_status(application)
    return unless application.letter_sent?

    case application.visa_outcome
    when "granted" then [ :success, "Visa granted" ]
    when "denied" then [ :error, "Visa refused" ]
    else [ :pending, "Waiting on the embassy" ]
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
