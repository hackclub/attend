# Finishing a guardian's part of a registration. The portal's "Submit and
# finish" button used to be the only way to complete a guardian link, and
# guardians who signed every waiver routinely never clicked it, leaving the
# participant "Awaiting Parent" forever. The button, the DocuSeal signing
# webhooks, and portal saves now all finish through #complete!, so the
# automatic path and the button do exactly the same thing.
class GuardianPortalCompletion
  attr_reader :guardian_participant_event

  # Completes every guardian on this registration whose portal steps are all
  # done. Returns how many were completed by this call.
  def self.complete_ready_guardians!(participant_event)
    participant_event.guardian_participant_events.reject(&:completed?).count do |guardian_participant_event|
      new(guardian_participant_event).complete!
    end
  end

  def initialize(guardian_participant_event)
    @guardian_participant_event = guardian_participant_event
  end

  # Idempotent: returns true only for the call that actually completed the
  # link. The row lock makes concurrent callers (the waiver and freedom waiver
  # webhooks landing together, or a webhook racing the button) serialize, and
  # the re-check under the lock means only one of them flips the status — so
  # the after_update_commit completion hook, and the confirmation email it
  # sends, fire once.
  def complete!
    completed_now = guardian_participant_event.with_lock do
      next false if guardian_participant_event.completed?
      next false unless steps_complete?

      # GuardianParticipantEvent's after_update_commit hook marks the
      # participant complete once every guardian is done.
      guardian_participant_event.update!(status: :completed, completed_at: Time.current)
      true
    end

    trigger_documents if completed_now
    completed_now
  end

  def steps_complete?
    guardian.legal_first_name.present? &&
      guardian.legal_last_name.present? &&
      guardian.email.present? &&
      guardian.phone.present? &&
      guardian_participant_event.emergency_contacts.any? &&
      consents_complete?
  end

  def consents_complete?
    pending_consent_types.empty?
  end

  def pending_consent_types
    pending = []

    # Check waiver (requires guardian signature)
    waiver_consent = participant_event.consents.find_by(consent_type: "waiver")
    pending << "waiver" unless waiver_consent&.guardian_signed?

    # Check freedom waiver (requires full signature since parent-only) - only if enabled
    if event.freedom_waivers_enabled?
      freedom_consent = participant_event.consents.find_by(consent_type: "freedom_waiver")
      pending << "freedom_waiver" unless freedom_consent&.signed?
    end

    # Physical custom documents the guardian can act on right now block
    # completion: guardian-only ones they must sign & upload themselves, and
    # participant uploads awaiting their review. (Dual-signer documents the
    # participant hasn't uploaded yet don't block — there's nothing to review.)
    participant_event.applicable_custom_documents.select(&:physical?).select(&:guardian_signs?).each do |doc|
      consent = participant_event.consents.find_by(consent_type: "custom_document", custom_document: doc)
      next if consent&.signed?

      if doc.signed_by_guardian? || consent&.physical_uploaded?
        pending << "custom_document_#{doc.id}"
      end
    end

    pending
  end

  def waivers_paused?
    Setting.waiver_sending_paused? || event.guardian_invites_locked?
  end

  def ensure_waiver_exists_and_triggered
    # While guardian invites are locked (or waiver sending is globally paused),
    # don't create consents or DocuSeal submissions — participant_events without
    # waiver consents are what SendPendingGuardianInvitesJob backfills on unlock.
    return if waivers_paused?

    # Create and trigger the main waiver
    waiver = participant_event.find_or_create_consent!(:waiver) do |c|
      c.status = :pending
      c.guardian_participant_event = guardian_participant_event
    end

    unless waiver.signed? || waiver.sent?
      DocusealJobs::CreateMinorWaiverJob.perform_later(waiver.id)
    end

    if waiver.failed?
      waiver.update!(status: :pending, failure_reason: nil)
      DocusealJobs::CreateMinorWaiverJob.perform_later(waiver.id)
    end

    # Create and trigger the freedom waiver (only if enabled for this event)
    return unless event.freedom_waivers_enabled?

    freedom_waiver = participant_event.find_or_create_consent!(:freedom_waiver) do |c|
      c.status = :pending
      c.guardian_participant_event = guardian_participant_event
    end

    unless freedom_waiver.signed? || freedom_waiver.sent?
      DocusealJobs::CreateFreedomWaiverJob.perform_later(freedom_waiver.id)
    end

    if freedom_waiver.failed?
      freedom_waiver.update!(status: :pending, failure_reason: nil)
      DocusealJobs::CreateFreedomWaiverJob.perform_later(freedom_waiver.id)
    end
  end

  # Guardian-only custom documents are the guardian's to sign — create their
  # submissions as soon as the portal is completed (DocuSeal emails the link)
  # instead of waiting for anyone to open a signing page.
  def ensure_guardian_custom_documents_triggered
    participant_event.applicable_custom_documents.select(&:signed_by_guardian?).each do |doc|
      consent = participant_event.consents.find_or_create_by!(consent_type: :custom_document, custom_document: doc) do |c|
        c.guardian_participant_event = guardian_participant_event
      end

      # Physical documents are signed on paper — nothing to send.
      next if doc.physical?

      if consent.docuseal_envelope_id.blank? && !consent.signed? && !consent.failed?
        DocusealJobs::CreateCustomDocumentJob.perform_later(consent.id)
      end
    end
  end

  private

  def trigger_documents
    ensure_waiver_exists_and_triggered
    ensure_guardian_custom_documents_triggered
  end

  def guardian
    guardian_participant_event.guardian
  end

  def participant_event
    guardian_participant_event.participant_event
  end

  def event
    participant_event.event
  end
end
