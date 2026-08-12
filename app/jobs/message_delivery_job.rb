class MessageDeliveryJob < ApplicationJob
  queue_as :default

  def perform(message_id:, retry_failed_only: false)
    message = Message.find(message_id)

    deliveries = if retry_failed_only
      message.message_deliveries.pending
    else
      message.message_deliveries.pending
    end

    deliveries.find_each do |delivery|
      SingleDeliveryJob.perform_later(delivery_id: delivery.id)
    end
  end
end
