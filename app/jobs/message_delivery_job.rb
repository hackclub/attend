class MessageDeliveryJob < ApplicationJob
  queue_as :default

  # Fans a message's pending deliveries out to SingleDeliveryJob. With
  # `delivery_ids`, only those rows are enqueued (a catch-up send must not
  # re-enqueue the original batch); without, every pending row is, which is
  # what the first send and "retry failed" want.
  def perform(message_id:, delivery_ids: nil)
    message = Message.find(message_id)

    pending = message.message_deliveries.pending
    pending = pending.where(id: delivery_ids) if delivery_ids

    jobs = pending.pluck(:id).map do |delivery_id|
      SingleDeliveryJob.new(delivery_id: delivery_id)
    end

    ActiveJob.perform_all_later(jobs)
  end
end
