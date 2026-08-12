module AirtableJobs
  class PushRecordJob < ApplicationJob
    queue_as :default

    def perform(participant_event_id)
      participant_event = ParticipantEvent.find(participant_event_id)
      sync_service = Airtable::SyncService.new(participant_event.event)
      sync_service.push_participant_event(participant_event)
    rescue Airtable::RateLimitError => e
      Rails.logger.warn("Airtable rate limit hit, retrying in 30 seconds")
      self.class.set(wait: 30.seconds).perform_later(participant_event_id)
    rescue Airtable::Error => e
      Rails.logger.error("Airtable push error: #{e.message}")
      raise
    end
  end
end
