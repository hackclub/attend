module AirtableJobs
  class PullChangesJob < ApplicationJob
    queue_as :default

    def perform(event_id, table_name: "Participants", since: nil)
      event = Event.find(event_id)
      since ||= 1.hour.ago

      sync_service = Airtable::SyncService.new(event)
      records = sync_service.pull_changes(table_name, since: since)

      records.each do |record|
        process_record(event, record)
      end
    rescue Airtable::RateLimitError => e
      Rails.logger.warn("Airtable rate limit hit, retrying in 30 seconds")
      self.class.set(wait: 30.seconds).perform_later(event_id, table_name: table_name, since: since)
    rescue Airtable::Error => e
      Rails.logger.error("Airtable sync error: #{e.message}")
      raise
    end

    private

    def process_record(event, record)
      participant_event_id = record.dig("fields", "Participant Event ID")
      return unless participant_event_id.present?

      participant_event = event.participant_events.find_by(id: participant_event_id)
      return unless participant_event

      update_from_airtable(participant_event, record["fields"])
    end

    def update_from_airtable(participant_event, fields)
      updates = {}
      updates[:status] = fields["Status"] if fields["Status"].present?

      participant_event.update!(updates) if updates.any?
    end
  end
end
