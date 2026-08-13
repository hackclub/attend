class MessageDeliveryJob < ApplicationJob
  queue_as :default

  def perform(message_id:)
    message = Message.find(message_id)

    jobs = message.message_deliveries.pending.pluck(:id).map do |delivery_id|
      SingleDeliveryJob.new(delivery_id: delivery_id)
    end

    ActiveJob.perform_all_later(jobs)
  end
end
