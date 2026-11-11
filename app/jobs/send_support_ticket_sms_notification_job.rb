class SendSupportTicketSmsNotificationJob < ApplicationJob
  queue_as :default

  THROTTLE_WINDOW = 15.minutes
  BODY_PREVIEW_LENGTH = 80
  CHANNEL_LABELS = { "sms" => "SMS", "whatsapp" => "WhatsApp", "signal" => "Signal" }.freeze

  def perform(ticket_message_id, kind)
    return unless Setting.support_sms_notifications_enabled?

    message = TicketMessage.find(ticket_message_id)
    ticket = message.ticket

    case kind.to_s
    when "new_ticket"
      notify_new_ticket(ticket, message)
    when "assigned_reply"
      notify_assigned_reply(ticket, message)
    end
  end

  private

  def notify_new_ticket(ticket, message)
    channel = CHANNEL_LABELS.fetch(ticket.channel, ticket.channel)
    body = "Attend: new support ticket from #{ticket.phone_number} via #{channel}: " \
           "\"#{preview(message)}\" #{ticket_url(ticket)}"

    variables = {
      1 => WhatsappTemplates.variable(ticket.phone_number),
      2 => WhatsappTemplates.variable(channel),
      3 => WhatsappTemplates.variable(preview(message)),
      4 => ticket.id
    }

    Setting.support_sms_notification_number_list.each do |number|
      send_notification(to: number, body:, ticket:, template: WhatsappTemplates::SUPPORT_NEW_TICKET, variables:)
    end
  end

  def notify_assigned_reply(ticket, message)
    phone = ticket.assigned_to&.phone.to_s.gsub(/[^\d+]/, "")
    return if phone.blank?
    return if throttled?(ticket)

    body = "Attend: new reply on your ticket ##{ticket.id[0..7]}: \"#{preview(message)}\" #{ticket_url(ticket)}"

    variables = {
      1 => ticket.id[0..7],
      2 => WhatsappTemplates.variable(preview(message)),
      3 => ticket.id
    }

    send_notification(to: phone, body:, ticket:, template: WhatsappTemplates::SUPPORT_TICKET_REPLY, variables:)
    Rails.cache.write(throttle_key(ticket), true, expires_in: THROTTLE_WINDOW)
  end

  def send_notification(to:, body:, ticket:, template:, variables:)
    TwilioService.new.send_message(
      to: to,
      sms_body: body,
      whatsapp_template: template,
      whatsapp_variables: variables,
      source: "Staff notifications"
    )
  rescue TwilioService::Error => e
    Rails.logger.error("[SupportTicketSms] notification to #{to} failed for ticket #{ticket.id}: #{e.message}")
  end

  def throttled?(ticket)
    Rails.cache.exist?(throttle_key(ticket))
  end

  def throttle_key(ticket)
    "support_sms_notify:#{ticket.id}"
  end

  def preview(message)
    message.body.to_s.truncate(BODY_PREVIEW_LENGTH)
  end

  def ticket_url(ticket)
    Rails.application.routes.url_helpers.support_ticket_url(ticket, host: app_host, protocol: "https")
  end

  def app_host
    ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options&.dig(:host) || "attend.hackclub.com" }
  end
end
