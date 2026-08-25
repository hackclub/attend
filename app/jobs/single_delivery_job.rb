class SingleDeliveryJob < ApplicationJob
  queue_as :default

  def perform(delivery_id:)
    delivery = MessageDelivery.find(delivery_id)
    return if delivery.delivered?

    delivery.update!(status: :sending)

    case delivery.channel
    when "slack"
      deliver_via_slack(delivery)
    when "email"
      deliver_via_email(delivery)
    when "sms"
      deliver_via_sms(delivery)
    when "push"
      deliver_via_push(delivery)
    else
      delivery.update!(status: :failed, error_message: "Unknown channel: #{delivery.channel}")
    end
  rescue StandardError => e
    delivery.update!(status: :failed, error_message: e.message)
    Rails.logger.error("[MessageDelivery] Failed delivery #{delivery.id}: #{e.message}")
  ensure
    delivery.message.update_counts!
    check_message_completion(delivery.message)
  end

  private

  # App push: notify the participant's mobile devices via Expo. Only participants
  # (not guardians) have the app, and they must have registered a push token.
  def deliver_via_push(delivery)
    participant = delivery.participant_event&.participant
    user = participant&.user

    unless user
      delivery.update!(status: :failed, error_message: "No app account for recipient")
      return
    end

    tokens = PushToken.for_users([ user ]).expo_tokens.pluck(:token)
    if tokens.blank?
      delivery.update!(status: :failed, error_message: "No registered devices")
      return
    end

    event = delivery.event
    title = event.name.presence || "Event update"
    body = delivery.message.subject.presence || delivery.message.body_as_plain.to_s.truncate(140)

    ExpoPushService.send_notification(
      tokens: tokens,
      title: title,
      body: body,
      data: {
        type: "message",
        participant_event_id: delivery.participant_event_id,
        message_id: delivery.message_id
      }
    )

    delivery.update!(status: :delivered, delivered_at: Time.current)
  end

  def deliver_via_slack(delivery)
    slack_user_id = delivery.recipient_slack_id

    unless slack_user_id.present?
      delivery.update!(status: :failed, error_message: "No Slack user ID")
      return
    end

    event = delivery.event
    message_url = message_url_for(delivery)

    message_body = delivery.message.body_as_slack
    footer = "\n\n_You're receiving this message because you're a confirmed attendee at #{event.name}._"

    slack_service = SlackService.new
    result = slack_service.send_dm_with_blocks(
      user_id: slack_user_id,
      text: message_body + footer,
      blocks: [
        {
          type: "section",
          text: { type: "mrkdwn", text: message_body + footer }
        },
        {
          type: "actions",
          elements: [
            {
              type: "button",
              text: { type: "plain_text", text: "View on Attend", emoji: true },
              url: message_url,
              style: "primary"
            }
          ]
        }
      ]
    )

    delivery.update!(
      status: :delivered,
      external_id: result[:ts],
      delivered_at: Time.current
    )
  rescue SlackService::Error => e
    delivery.update!(status: :failed, error_message: e.message)
  end

  def deliver_via_email(delivery)
    email = delivery.recipient_email

    unless email.present?
      delivery.update!(status: :failed, error_message: "No email address")
      return
    end

    MessageMailer.broadcast(delivery: delivery).deliver_now

    delivery.update!(
      status: :delivered,
      delivered_at: Time.current
    )
  rescue => e
    delivery.update!(status: :failed, error_message: e.message)
  end

  def deliver_via_sms(delivery)
    phone = delivery.recipient_phone

    unless phone.present?
      delivery.update!(status: :failed, error_message: "No phone number")
      return
    end

    message_url = message_url_for(delivery)
    plain_body = delivery.message.body_as_plain

    truncated_body = if plain_body.length > 200
      plain_body[0, 197] + "..."
    else
      plain_body
    end

    sms_body = "#{truncated_body}\n\nView on Attend: #{message_url}"

    sms_service = TwilioService.new
    result = sms_service.send_sms(
      to: phone,
      body: sms_body
    )

    if result[:skipped]
      delivery.update!(status: :failed, error_message: result[:reason])
      return
    end

    delivery.update!(
      status: :delivered,
      external_id: result[:sid],
      delivered_at: Time.current
    )
  rescue TwilioService::Error => e
    delivery.update!(status: :failed, error_message: e.message)
  end

  def check_message_completion(message)
    return if message.message_deliveries.pending.any? || message.message_deliveries.sending.any?

    if message.message_deliveries.failed.any?
      message.update!(status: :failed) if message.sent_count.zero?
    else
      message.update!(status: :completed)
    end
  end

  def message_url_for(delivery)
    Rails.application.routes.url_helpers.dashboard_message_url(
      delivery,
      host: default_host,
      protocol: default_protocol
    )
  end

  def default_host
    ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "attend.hackclub.com" }
  end

  def default_protocol
    Rails.env.local? ? "http" : "https"
  end
end
