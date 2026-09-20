class RegistrationCompletionPresenter
  Task = Data.define(:owner, :kind, :name, :consent, :custom_document, :guardian_participant_event, :status)

  attr_reader :participant_event, :viewer, :guardian_participant_event

  def initialize(participant_event, viewer:, guardian_participant_event: nil)
    @participant_event = participant_event
    @viewer = viewer.to_sym
    @guardian_participant_event = guardian_participant_event

    raise ArgumentError, "viewer must be participant or guardian" unless @viewer.in?([ :participant, :guardian ])
    if @viewer == :guardian && @guardian_participant_event.nil?
      raise ArgumentError, "guardian_participant_event is required for a guardian viewer"
    end
  end

  def information_submitted?
    participant_event.code_of_conduct_accepted_at.present?
  end

  def confirmed?
    participant_event.complete? && participant_event.eligible_for_completion?
  end

  alias_method :entry_pass_eligible?, :confirmed?

  def viewer_tasks_complete?
    outstanding_tasks.none? { |task| task_belongs_to_viewer?(task) }
  end

  def state
    return :withdrawn if participant_event.withdrawn?
    return :rejected if participant_event.rejected?
    return :confirmed if confirmed?
    return :information_needed unless information_submitted?
    return :action_needed if actionable_viewer_task
    return :staff_attention if outstanding_tasks.any? { |task| task.owner == :staff && task.status == :failed }
    return :paused if outstanding_tasks.any? { |task| task.owner == :staff && task.status == :paused }
    return :preparing if outstanding_tasks.any? { |task| task.owner == :document_preparation }
    return :processing if outstanding_tasks.any? { |task| task.owner == :document_processing }
    if viewer == :guardian
      return :waiting_on_participant if outstanding_tasks.any? { |task| task.owner == :participant }
    end
    return :waiting_on_guardian if outstanding_tasks.any? { |task| task.owner == :guardian }

    :processing
  end

  def outstanding_tasks
    @outstanding_tasks ||= begin
      tasks = []
      tasks << task(:participant, :submission, "registration information", status: :actionable) unless information_submitted?
      tasks.concat(guardian_profile_tasks)
      tasks.concat(waiver_tasks)
      tasks.concat(freedom_waiver_tasks)
      tasks.concat(custom_document_tasks)
      tasks
    end
  end

  def next_task
    case state
    when :information_needed
      outstanding_tasks.find { |task| task.kind == :submission }
    when :action_needed
      actionable_viewer_task
    when :paused
      outstanding_tasks.find { |task| task.owner == :staff && task.status == :paused }
    when :staff_attention
      outstanding_tasks.find { |task| task.owner == :staff && task.status == :failed }
    when :preparing
      outstanding_tasks.find { |task| task.owner == :document_preparation }
    when :processing
      outstanding_tasks.find { |task| task.owner == :document_processing }
    when :waiting_on_guardian
      outstanding_tasks.find { |task| task.owner == :guardian }
    when :waiting_on_participant
      outstanding_tasks.find { |task| task.owner == :participant }
    end
  end

  def label
    {
      withdrawn: "Withdrawn",
      rejected: "Rejected",
      confirmed: "Registration confirmed",
      information_needed: "Information needed",
      action_needed: "Action needed",
      paused: "Documents paused",
      staff_attention: "Documents need attention",
      preparing: "Preparing documents",
      processing: "Processing",
      waiting_on_guardian: "Waiting on parent/guardian",
      waiting_on_participant: "Waiting on attendee"
    }.fetch(state)
  end

  def headline
    return "Documents are being prepared" if state == :preparing
    return label unless state == :processing && viewer == :guardian

    "Signatures received"
  end

  def body
    case state
    when :confirmed
      confirmed_body
    when :information_needed
      "Finish your information and submit it to continue your registration."
    when :action_needed
      action_needed_body
    when :paused
      "Your information is submitted. Signing isn't open yet. Please check back later or contact the event organizers."
    when :staff_attention
      "The event team needs to retry the #{next_task.name} before signing can continue. No action is needed from you right now."
    when :preparing
      "Your information is submitted. We're preparing the signing documents. Please check back shortly."
    when :processing
      processing_body
    when :waiting_on_guardian
      waiting_on_guardian_body
    when :waiting_on_participant
      waiting_on_participant_body
    when :withdrawn
      "This registration has been withdrawn."
    when :rejected
      "This registration was not accepted."
    end
  end

  private

  def participant
    participant_event.participant
  end

  def event
    participant_event.event
  end

  def consents
    @consents ||= participant_event.consents.to_a
  end

  def guardians
    @guardians ||= participant_event.guardian_participant_events.to_a
  end

  def primary_guardian
    guardians.find(&:is_primary_guardian) || guardians.first
  end

  def task(owner, kind, name, consent: nil, custom_document: nil, guardian_participant_event: nil, status:)
    Task.new(owner:, kind:, name:, consent:, custom_document:, guardian_participant_event:, status:)
  end

  def guardian_profile_tasks
    return [] unless participant_event.requires_guardian?
    if guardians.empty?
      return [ task(:guardian, :guardian_profile, "guardian information", status: :actionable) ]
    end

    guardians.reject(&:completed?).map do |guardian_link|
      task(:guardian, :guardian_profile, "guardian information",
        guardian_participant_event: guardian_link, status: :actionable)
    end
  end

  def waiver_tasks
    consent = consent_for(:waiver)
    signature_tasks(
      kind: :waiver,
      name: "event waiver",
      consent: consent,
      participant_required: true,
      guardian_required: participant_event.requires_guardian?
    )
  end

  def freedom_waiver_tasks
    return [] unless participant_event.requires_guardian? && event.freedom_waivers_enabled?

    signature_tasks(
      kind: :freedom_waiver,
      name: "Freedom Waiver",
      consent: consent_for(:freedom_waiver),
      participant_required: false,
      guardian_required: true
    )
  end

  def custom_document_tasks
    participant_event.applicable_custom_documents.flat_map do |document|
      signature_tasks(
        kind: :custom_document,
        name: document.name,
        consent: consents.find { |consent| consent.custom_document_id == document.id },
        custom_document: document,
        participant_required: document.participant_signs?,
        guardian_required: participant_event.requires_guardian? && document.guardian_signs?,
        physical: document.physical?
      )
    end
  end

  def signature_tasks(kind:, name:, consent:, participant_required:, guardian_required:, custom_document: nil, physical: false)
    return [] if consent&.signed?

    participant_done = !participant_required || consent&.participant_portion_signed?
    guardian_done = !guardian_required || consent&.guardian_signed?

    if participant_done && guardian_done
      return [ task(:document_processing, kind, name, consent:, custom_document:, status: :processing) ]
    end

    signer_tasks = []
    signer_tasks << participant_signature_task(kind:, name:, consent:, custom_document:, physical:) unless participant_done
    if !guardian_done
      signer_tasks << guardian_signature_task(
        kind:, name:, consent:, custom_document:, physical:,
        waiting_on_participant: participant_required && !participant_done
      )
    end

    if documents_paused?
      return signer_tasks.map { |signer_task| signer_task.with(status: :paused) } +
        [ task(:staff, kind, name, consent:, custom_document:, status: :paused) ]
    end

    if consent&.failed?
      return signer_tasks.map { |signer_task| signer_task.with(status: :waiting) } +
        [ task(:staff, kind, name, consent:, custom_document:, status: :failed) ]
    end

    if signer_tasks.any? { |signer_task| signer_task.status == :preparing }
      signer_tasks << task(:document_preparation, kind, name, consent:, custom_document:, status: :preparing)
    end

    signer_tasks
  end

  def participant_signature_task(kind:, name:, consent:, custom_document:, physical:)
    # Custom-document routes create or prepare their submission on entry, so
    # they remain a real user action even before DocuSeal has supplied a slug.
    ready = physical || custom_document.present? || consent&.docuseal_participant_slug.present?
    task(:participant, kind, name, consent:, custom_document:, status: ready ? :actionable : :preparing)
  end

  def guardian_signature_task(kind:, name:, consent:, custom_document:, physical:, waiting_on_participant:)
    ready = !waiting_on_participant &&
      (physical || custom_document.present? || consent&.docuseal_guardian_slug.present?)
    status = if waiting_on_participant
      :waiting
    elsif ready
      :actionable
    else
      :preparing
    end

    task(:guardian, kind, name, consent:, custom_document:,
      guardian_participant_event: consent&.guardian_participant_event || primary_guardian,
      status: status)
  end

  def consent_for(type)
    consents.find { |consent| consent.consent_type == type.to_s }
  end

  def documents_paused?
    Setting.waiver_sending_paused? || event.guardian_invites_locked?
  end

  def actionable_viewer_task
    outstanding_tasks.find { |task| task_belongs_to_viewer?(task) && task.status == :actionable }
  end

  def task_belongs_to_viewer?(task)
    return false unless task.owner == viewer
    return true unless viewer == :guardian

    task.guardian_participant_event == guardian_participant_event
  end

  def first_name
    participant.preferred_name.presence || participant.legal_first_name
  end

  def action_needed_body
    prefix = information_submitted? ? "Your information is submitted. " : ""
    "#{prefix}Please #{action_phrase(next_task)}."
  end

  def action_phrase(target_task)
    case target_task.kind
    when :submission
      "complete your registration information"
    when :guardian_profile
      "complete the guardian information"
    else
      "sign the #{target_task.name}"
    end
  end

  def confirmed_body
    if viewer == :guardian
      "#{first_name}'s registration is confirmed and their entry ticket is ready."
    else
      "Your registration is confirmed and your entry ticket is ready."
    end
  end

  def processing_body
    if viewer == :guardian && viewer_tasks_complete?
      "Your tasks are complete. We're processing the signed documents and will update the registration when that finishes."
    else
      "Your information is submitted. We're processing the signed documents and will update this page when that finishes."
    end
  end

  def waiting_on_guardian_body
    guardian_link = next_task.guardian_participant_event
    guardian = guardian_link&.guardian
    guardian_name = guardian&.legal_first_name.presence || "Your parent/guardian"
    guardian_email = guardian&.email
    invitation = guardian_email.present? ? " We sent their invitation to #{guardian_email}." : ""
    prefix = viewer == :guardian ? "Your tasks are complete. " : "Your information and signatures are complete. "
    "#{prefix}#{guardian_name} still needs to #{action_phrase(next_task)}.#{invitation}"
  end

  def waiting_on_participant_body
    prefix = viewer_tasks_complete? ? "Your tasks are complete. " : "Your information is submitted. "
    suffix = viewer_tasks_complete? ? "" : " first. You'll be able to finish your part after that."
    "#{prefix}#{first_name} still needs to #{action_phrase(next_task)}#{suffix}"
  end
end
