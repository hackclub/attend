class ProcessScheduledMessagesJob < ApplicationJob
  queue_as :default

  def perform
    Message.pending_scheduled.find_each do |message|
      Rails.logger.info("[ScheduledMessages] Processing scheduled message #{message.id}")

      message.send!
    end
  end
end
