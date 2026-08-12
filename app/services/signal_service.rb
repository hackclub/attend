class SignalService
  class Error < StandardError; end

  def initialize
    @base_url = Rails.application.credentials.dig(:signal, :api_base_url) ||
                ENV.fetch("SIGNAL_API_BASE_URL", "https://signal-api.attend.hackclub.com")
    @auth_token = Rails.application.credentials.dig(:signal, :api_auth_token) ||
                  ENV.fetch("SIGNAL_API_AUTH_TOKEN")
    @account_number = Rails.application.credentials.dig(:signal, :account_number) ||
                      ENV.fetch("SIGNAL_ACCOUNT_NUMBER")
  end

  def send_message(to:, body:, client_message_id: nil)
    payload = {
      to: to,
      body: body,
      from: @account_number
    }
    payload[:clientMessageId] = client_message_id if client_message_id.present?

    response = connection.post("/v1/messages") do |req|
      req.body = payload.to_json
    end

    unless response.success?
      raise Error, "Signal API error: #{response.status} - #{response.body}"
    end

    JSON.parse(response.body)
  end

  def get_message(message_sid)
    response = connection.get("/v1/messages/#{message_sid}")

    unless response.success?
      raise Error, "Signal API error: #{response.status} - #{response.body}"
    end

    JSON.parse(response.body)
  end

  def health_check
    response = connection.get("/health/ready")
    response.success?
  rescue Faraday::Error
    false
  end

  def self.verify_webhook_signature(payload:, signature:, timestamp:)
    secret = Rails.application.credentials.dig(:signal, :webhook_hmac_secret) ||
             ENV.fetch("SIGNAL_WEBHOOK_HMAC_SECRET")

    message = "#{timestamp}.#{payload}"
    expected_signature = OpenSSL::HMAC.hexdigest("SHA256", secret, message)

    ActiveSupport::SecurityUtils.secure_compare(signature, expected_signature)
  end

  private

  def connection
    @connection ||= Faraday.new(url: @base_url) do |f|
      f.request :json
      f.response :raise_error
      f.headers["Authorization"] = "Bearer #{@auth_token}"
      f.headers["Content-Type"] = "application/json"
      f.options.timeout = 30
      f.adapter Faraday.default_adapter
    end
  end
end
