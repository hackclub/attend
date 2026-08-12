class SendVoiceFollowupSmsJob < ApplicationJob
  queue_as :default

  WHATSAPP_FROM_NUMBER = "+18556254225".freeze
  CONTENT_TEMPLATE_SID = "HX47652dd17b8b0e0edce6ae3d622895a7".freeze

  def perform(phone_number)
    # Strip any existing whatsapp: prefix
    clean_number = phone_number.to_s.sub(/\Awhatsapp:/, "")

    client = Twilio::REST::Client.new(
      Rails.application.credentials.dig(:twilio, :account_sid) || ENV.fetch("TWILIO_ACCOUNT_SID"),
      Rails.application.credentials.dig(:twilio, :auth_token) || ENV.fetch("TWILIO_AUTH_TOKEN")
    )

    client.messages.create(
      from: "whatsapp:#{WHATSAPP_FROM_NUMBER}",
      to: "whatsapp:#{clean_number}",
      content_sid: CONTENT_TEMPLATE_SID
    )

    Rails.logger.info("[VoiceFollowupSms] Sent WhatsApp followup to #{phone_number}")
  rescue Twilio::REST::RestError => e
    Rails.logger.error("[VoiceFollowupSms] Failed to send WhatsApp to #{phone_number}: #{e.message}")
  end
end
