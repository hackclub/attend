class ProcessScheduledMessagesJob < ApplicationJob
  queue_as :default

  # Sent as the author but without trusting them: scheduling screened the
  # content and recorded its digest, so an untouched broadcast goes straight
  # out, but one edited since (possibly by someone else) is screened rather
  # than riding on its author's global-admin exemption.
  def perform
    Message.pending_scheduled.find_each do |message|
      Rails.logger.info("[ScheduledMessages] Processing scheduled message #{message.id}")

      message.send!(trust_sender: false)
    end

    SeriesBroadcast.pending_scheduled.find_each do |broadcast|
      Rails.logger.info("[ScheduledMessages] Processing scheduled series broadcast #{broadcast.id}")

      broadcast.send!(trust_sender: false)
    end
  end
end
