module Twilio
  class StatusCallbacksController < ActionController::Base
    skip_before_action :verify_authenticity_token
    before_action :validate_twilio_signature!

    def create
      ::Support::UpdateTwilioMessageStatus.call(params.to_unsafe_h)
      head :ok
    rescue => e
      Rails.logger.error("[Twilio::StatusCallbacks] #{e.class}: #{e.message}")
      head :internal_server_error
    end

    private

    def validate_twilio_signature!
      return if Rails.env.development? && skip_validation_in_dev?

      auth_token = Rails.application.credentials.dig(:twilio, :auth_token) ||
                   ENV.fetch("TWILIO_AUTH_TOKEN", nil)

      unless auth_token.present?
        Rails.logger.warn("[Twilio::StatusCallbacks] No auth token configured")
        head :forbidden
        return
      end

      validator = ::Twilio::Security::RequestValidator.new(auth_token)
      signature = request.headers["X-Twilio-Signature"]
      url = request.original_url
      params_hash = request.request_parameters

      unless validator.validate(url, params_hash, signature)
        Rails.logger.warn("[Twilio::StatusCallbacks] Invalid Twilio signature")
        head :forbidden
      end
    end

    def skip_validation_in_dev?
      ENV["SKIP_TWILIO_VALIDATION"] == "true"
    end
  end
end
