class ProcessPausedWaiversJob < ApplicationJob
  queue_as :default

  def perform
    # Re-check paused state in case admin re-paused after unpausing enqueued this job
    return if Setting.waiver_sending_paused?

    # Find participant_events that finished registration but have no waiver sent to DocuSeal.
    # This catches participants who registered while waiver sending was paused.
    participant_events = ParticipantEvent
      .where(status: %w[awaiting_guardian complete])
      .where.not(
        id: Consent.where(consent_type: :waiver).where(status: %w[sent viewed signed pending]).select(:participant_event_id)
      )

    count = 0
    participant_events.find_each do |pe|
      process_participant_event(pe)
      count += 1
    rescue => e
      Rails.logger.error("ProcessPausedWaiversJob: Failed for ParticipantEvent##{pe.id}: #{e.message}")
    end

    Rails.logger.info("ProcessPausedWaiversJob: Enqueued waivers for #{count} participant(s)")
  end

  private

  def process_participant_event(pe)
    if pe.requires_guardian?
      guardian_pe = pe.guardian_participant_events.first
      return unless guardian_pe

      consent = pe.consents.find_or_create_by!(consent_type: :waiver) do |c|
        c.status = :pending
        c.guardian_participant_event = guardian_pe
      end

      unless consent.signed? || consent.sent? || consent.viewed?
        consent.update!(status: :pending, failure_reason: nil) if consent.failed?
        DocusealJobs::CreateMinorWaiverJob.perform_later(consent.id)
      end
    else
      consent = pe.consents.find_or_create_by!(consent_type: :waiver) do |c|
        c.status = :pending
      end

      unless consent.signed? || consent.sent? || consent.viewed?
        consent.update!(status: :pending, failure_reason: nil) if consent.failed?
        DocusealJobs::CreateAdultWaiverJob.perform_later(consent.id)
      end
    end
  end
end
