class WalletPassUpdateJob < ApplicationJob
  queue_as :default

  def perform(participant_event_id)
    participant_event = ParticipantEvent.find_by(id: participant_event_id)
    return unless participant_event

    WalletPassUpdateService.update_passes_for(participant_event)
  end
end
