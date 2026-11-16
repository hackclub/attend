# Re-derives every registration's status at an event after something
# event-wide changed what they need: a module switched on or off, or the
# dates moving (which can change who counts as a minor).
#
# Someone this takes out of complete has lost their ticket through nothing
# they did, so ParticipantEvent#sync_status! emails them what is now needed.
class ResyncRegistrationsJob < ApplicationJob
  queue_as :default

  def perform(event_id, cause = "settings_changed")
    event = Event.find_by(id: event_id)
    return unless event

    changed = 0
    failed = 0
    event.participant_events.active.find_each do |participant_event|
      changed += 1 if participant_event.sync_status!(cause: cause, actor: nil)
    rescue StandardError => e
      # One registration that can't be saved (a row the model would now
      # reject, one deleted mid-run) mustn't leave the rest of the event
      # behind. The nightly drift check picks up whatever is skipped here.
      failed += 1
      Rails.error.report(e, handled: true, context: { participant_event_id: participant_event.id, event_id: event.id })
    end

    Rails.logger.info(
      "[ResyncRegistrationsJob] #{changed} registrations changed status at event #{event.id} (#{cause}), #{failed} failed"
    )
  end
end
