# Adding and backing out of optional custom documents — waivers for opt-in
# activities (zip lining, a hike) that only apply to participants who say they
# want to take part.
#
# The consent row is the opt-in record. Until the participant adds the
# document there is no row, so CustomDocument#applies_to? returns false and
# the document is invisible everywhere — including the guardian portal, which
# is the point: a parent should never be handed a waiver for an activity their
# child isn't doing, nor be left thinking one was missed.
module OptionalDocumentEnrolment
  extend ActiveSupport::Concern

  private

  # Adds the document for this participant. Idempotent — adding one that's
  # already added is a no-op, and re-adding one they backed out of restores
  # whatever was already signed rather than starting over.
  def enrol_in_optional_document(participant_event, custom_document)
    existing = participant_event.consents.find_by(
      consent_type: :custom_document, custom_document: custom_document
    )
    # Already added — a double-submitted "Add" must not re-email the guardian.
    return existing if existing && !existing.withdrawn?

    consent = existing ? existing.tap(&:reinstate!) : create_optional_consent(participant_event, custom_document)

    participant_event.consents.reload
    participant_event.reset_document_memoisation!

    # The participant just took on a new blocking document. Keep the stored
    # status honest with the live one, for the same reason
    # ReopenParticipantsForCustomDocumentsJob exists — message audiences,
    # Airtable sync, and raw-status filters all read the column.
    if participant_event.complete? && !consent.signed?
      participant_event.update!(status: :in_progress)
    end

    notify_guardian_of_optional_document(participant_event, custom_document, consent)
    consent
  end

  # Two "Add" submissions racing each other both get past the find_by above;
  # the unique index on (participant_event_id, custom_document_id) settles it,
  # and the loser takes the winner's row rather than blowing up.
  def create_optional_consent(participant_event, custom_document)
    participant_event.consents.create!(
      consent_type: :custom_document,
      custom_document: custom_document,
      opted_in_at: Time.current,
      guardian_participant_event: guardian_for_optional_document(participant_event, custom_document)
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Re-raise if it wasn't the race — a real validation failure shouldn't
    # disappear into a nil consent.
    participant_event.consents.reload.find_by(
      consent_type: :custom_document, custom_document: custom_document
    ) || raise
  end

  # Backs the participant out. Signed consents are withdrawn, never destroyed:
  # the signature already happened and stays on file as a record, it just no
  # longer applies to this participant's registration.
  def withdraw_from_optional_document(participant_event, custom_document)
    consent = participant_event.consents.find_by(
      consent_type: :custom_document, custom_document: custom_document
    )
    return nil if consent.nil? || consent.withdrawn?

    consent.withdraw!

    participant_event.consents.reload
    participant_event.reset_document_memoisation!
    participant_event.mark_complete_if_eligible!

    consent
  end

  def guardian_for_optional_document(participant_event, custom_document)
    return nil unless custom_document.guardian_signs? && participant_event.requires_guardian?

    participant_event.primary_guardian || participant_event.guardian_participant_events.first
  end

  # A guardian who is still working through their portal will meet the
  # document there on their own. One who already finished won't come back
  # unless we tell them, so they get an email with a link straight to it.
  def notify_guardian_of_optional_document(participant_event, custom_document, consent)
    return unless custom_document.guardian_signs? && participant_event.requires_guardian?
    return if consent.signed?
    return if participant_event.event.guardian_invites_locked?

    guardian_participant_event = consent.guardian_participant_event ||
                                 guardian_for_optional_document(participant_event, custom_document)
    return unless guardian_participant_event&.completed?

    GuardianMailer.optional_document_added(
      guardian_participant_event: guardian_participant_event,
      custom_document: custom_document
    ).deliver_later
  end
end
