class ProcessScheduledMessagesJob < ApplicationJob
  queue_as :default

  def perform
    Message.pending_scheduled.find_each do |message|
      Rails.logger.info("[ScheduledMessages] Processing scheduled message #{message.id}")

      recipients = message.recipients

      if message.guardian_audience?
        recipients.find_each do |guardian|
          message.channels.each do |channel|
            next unless can_deliver_to_guardian?(guardian, channel)

            message.message_deliveries.create!(
              guardian: guardian,
              channel: channel,
              recipient_email: guardian.email,
              recipient_phone: guardian.phone,
              status: :pending
            )
          end
        end
      else
        recipients.find_each do |participant_event|
          message.channels.each do |channel|
            next unless can_deliver_to_participant?(participant_event, channel)

            message.message_deliveries.create!(
              participant_event: participant_event,
              channel: channel,
              recipient_email: participant_event.participant.email,
              recipient_phone: participant_event.participant.phone,
              recipient_slack_id: participant_event.participant.slack_user_id,
              status: :pending
            )
          end
        end
      end

      message.update!(
        status: :sending,
        recipient_count: message.message_deliveries.count,
        sent_at: Time.current
      )

      MessageDeliveryJob.perform_later(message_id: message.id)
    end
  end

  private

  def can_deliver_to_participant?(participant_event, channel)
    case channel.to_s
    when "slack"
      participant_event.participant.slack_user_id.present?
    when "email"
      participant_event.participant.email.present?
    when "sms"
      participant_event.participant.phone.present?
    else
      false
    end
  end

  def can_deliver_to_guardian?(guardian, channel)
    case channel.to_s
    when "slack"
      false
    when "email"
      guardian.email.present?
    when "sms"
      guardian.phone.present?
    else
      false
    end
  end
end
