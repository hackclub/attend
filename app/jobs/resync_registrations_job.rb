# Re-derives every registration's status at an event after something
# event-wide changed what they need: a module switched on or off, or the
# dates moving (which can change who counts as a minor).
class ResyncRegistrationsJob < ApplicationJob
  queue_as :default

  def perform(event_id, cause = "settings_changed")
    event = Event.find_by(id: event_id)
    return unless event

    changed = 0
    event.participant_events.active.find_each do |participant_event|
      changed += 1 if participant_event.sync_status!(cause: cause, actor: nil)
    end

    Rails.logger.info("[ResyncRegistrationsJob] #{changed} registrations changed status at event #{event.id} (#{cause})")
  end
end
