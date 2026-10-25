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
    # A fresh query rather than the association, so the caller's loaded
    # guardian_participant_events (and their order) stay as they were.
    participant_event.guardian_participant_events.where.not(status: :completed).count do |guardian_participant_event|
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
    # Most calls (every step save, every signing webhook) come before the
    # guardian is ready, so check without the lock first.
    return false unless ready?

    completed_now = guardian_participant_event.with_lock do
      next false unless ready?

      # GuardianParticipantEvent's after_update_commit hook marks the
      # participant complete once every guardian is done. Links finished from
      # a webhook or a signing return never went through
      # mark_accepted_if_needed; without accepted_at, a later "Submit and
      # finish" press would mark_accepted! the link back to in_progress.
      guardian_participant_event.update!(status: :completed, completed_at: Time.current,
        accepted_at: guardian_participant_event.accepted_at || Time.current)
      true
    end

    trigger_documents_reporting_failures if completed_now
    completed_now
  end

  # The overview's four sections. Automatic completion locks the guardian out
  # of the portal, so it must wait for the same sections the overview ticks,
  # not just the fields the old button checked.
  def steps_complete?
    participant_info_complete? &&
      details_complete? &&
      guardian_participant_event.emergency_contacts.any? &&
      consents_complete?
  end

  def participant_info_complete?
    guardian_participant_event.participant_info_reviewed_at.present?
  end

  def details_complete?
    guardian.legal_first_name.present? &&
      guardian.legal_last_name.present? &&
      guardian.email.present? &&
      guardian.phone.present? &&
      guardian_participant_event.relationship.present? &&
      guardian.address_line_1.present? &&
      guardian.city.present? &&
      guardian.state.present? &&
      guardian.postal_code.present? &&
      guardian.country.present?
  end

  def consents_complete?
    pending_consent_types.empty?
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

  private

  # A withdrawn or rejected registration is closed: a guardian finishing a
  # DocuSeal link that was still open must not complete, or the commit hook
  # would flip the registration back to complete and send its confirmation.
  def ready?
    !guardian_participant_event.completed? &&
      !(participant_event.withdrawn? || participant_event.rejected?) &&
      steps_complete?
  end

  def pending_consent_types
    pending = []

    # One query (never the cached association, which may predate a signature
    # made earlier in this request) instead of a find_by per document.
    consents = participant_event.consents.where(consent_type: %w[waiver freedom_waiver custom_document]).to_a
    custom_document_consents = consents.select(&:custom_document?).index_by(&:custom_document_id)

    # Check waiver (requires guardian signature)
    waiver_consent = consents.find(&:waiver?)
    pending << "waiver" unless waiver_consent&.guardian_signed?

    # Check freedom waiver (requires full signature since parent-only) - only if enabled
    if event.freedom_waivers_enabled?
      freedom_consent = consents.find(&:freedom_waiver?)
      pending << "freedom_waiver" unless freedom_consent&.signed?
    end

    # Physical custom documents the guardian can act on right now block
    # completion: guardian-only ones they must sign & upload themselves, and
    # participant uploads awaiting their review. (Dual-signer documents the
    # participant hasn't uploaded yet don't block — there's nothing to review.)
    participant_event.applicable_custom_documents.select(&:physical?).select(&:guardian_signs?).each do |doc|
      consent = custom_document_consents[doc.id]
      next if consent&.signed?

      if doc.signed_by_guardian? || consent&.physical_uploaded?
        pending << "custom_document_#{doc.id}"
      end
    end

    pending
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

  def trigger_documents
    ensure_waiver_exists_and_triggered
    ensure_guardian_custom_documents_triggered
  end

  # The link is already committed as completed, so a failure here can't be
  # retried by calling #complete! again. Report it rather than failing the
  # caller (a webhook would 422 and skip the waiver notification); the
  # guardian's signing pages, reachable from the confirmed page, create any
  # missing submission on open.
  def trigger_documents_reporting_failures
    trigger_documents
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { guardian_participant_event_id: guardian_participant_event.id })
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
