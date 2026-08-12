class ExpoPushService
  EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send"

  def self.send_notification(tokens:, title:, body:, data: {})
    return if tokens.blank?

    messages = tokens.map do |token|
      {
        to: token,
        sound: "default",
        title: title,
        body: body,
        data: data
      }
    end

    response = Faraday.post(EXPO_PUSH_URL) do |req|
      req.headers["Content-Type"] = "application/json"
      req.headers["Accept"] = "application/json"
      req.body = messages.to_json
    end

    if response.success?
      Rails.logger.info("[ExpoPushService] Sent #{messages.size} notifications")
      JSON.parse(response.body)
    else
      Rails.logger.error("[ExpoPushService] Failed to send notifications: #{response.body}")
      nil
    end
  rescue Faraday::Error => e
    Rails.logger.error("[ExpoPushService] Network error: #{e.message}")
    nil
  end

  def self.notify_flight_landed(event:, participant_name:, flight_code:, participant_event_id:)
    tokens = PushToken.for_users(event.staff_users).expo_tokens.pluck(:token)
    return if tokens.blank?

    send_notification(
      tokens: tokens,
      title: "✈️ Flight Landed",
      body: "#{participant_name}'s flight #{flight_code} has landed",
      data: {
        type: "flight_landed",
        participant_event_id: participant_event_id,
        flight_code: flight_code
      }
    )
  end
end
