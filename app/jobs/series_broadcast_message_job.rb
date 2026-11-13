# Sends one event's copy of a SeriesBroadcast through the ordinary per-event
# pipeline (Message#send!), which only sends a draft, so a retry or a second
# fan-out can't send it twice. The copy was screened as part of the
# broadcast, so it goes out without being screened again.
class SeriesBroadcastMessageJob < ApplicationJob
  queue_as :default

  def perform(message_id:)
    message = Message.find_by(id: message_id)
    return unless message&.series_broadcast

    message.send!(sender: message.series_broadcast.sent_by_user)

    # Nobody on the event could be reached on the chosen channels, so no
    # delivery will ever settle it: it is done now.
    message.reload
    message.update!(status: :completed) if message.sending? && !message.message_deliveries.exists?
  end
end
