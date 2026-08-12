class ReopenParticipantsForCustomDocumentsJob < ApplicationJob
  queue_as :default

  # A custom document added after participants completed onboarding leaves
  # their db status 'complete' while the live display shows a blocking
  # custom_documents step — so message audiences, Airtable sync, and raw-status
  # filters disagree with the admin list. Regress those participants to
  # in_progress and tell them a new document is waiting; signing it re-completes
  # them through ParticipantEvent#mark_complete_if_eligible!.
  def perform(event_id)
    event = Event.find(event_id)

    # While guardian invites are locked, documents are not supposed to be
    # signed — the unlock hook (Event#send_pending_guardian_invites) re-enqueues.
    return if event.guardian_invites_locked?

    documents = event.custom_documents.active.to_a
    return if documents.none?

    reopened = 0
    event.participant_events.complete.includes(:participant, :consents).find_each do |participant_event|
      needs_signature = documents.any? do |doc|
        doc.applies_to?(participant_event) && !participant_event.custom_document_signed?(doc)
      end
      next unless needs_signature

      participant_event.update!(status: :in_progress)
      ParticipantMailer.new_document_ready(participant_event: participant_event).deliver_later
      reopened += 1
    end

    Rails.logger.info("[ReopenParticipantsForCustomDocumentsJob] Reopened #{reopened} complete participants for event #{event.id}")
  end
end
