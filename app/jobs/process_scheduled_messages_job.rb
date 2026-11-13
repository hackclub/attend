class ProcessScheduledMessagesJob < ApplicationJob
  queue_as :default

  # Sent with no sender: scheduling screened the content and recorded its
  # digest, so an untouched broadcast goes straight out, but one edited since
  # (possibly by someone else) is screened rather than riding on its
  # creator's global-admin exemption.
  def perform
    Message.pending_scheduled.find_each do |message|
      Rails.logger.info("[ScheduledMessages] Processing scheduled message #{message.id}")

      message.send!(sender: nil)
    end

    SeriesBroadcast.pending_scheduled.find_each do |broadcast|
      Rails.logger.info("[ScheduledMessages] Processing scheduled series broadcast #{broadcast.id}")

      broadcast.send!(sender: nil)
    end
  end
end
