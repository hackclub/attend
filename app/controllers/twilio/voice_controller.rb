module Twilio
  class VoiceController < ActionController::Base
    skip_before_action :verify_authenticity_token
    before_action :validate_twilio_signature!

    SUPPORT_NUMBER = "+18022333223".freeze
    WHATSAPP_FROM_NUMBER = "+18556254225".freeze

    def incoming
      caller_number = params["From"]

      if caller_number.present?
        SendVoiceFollowupSmsJob.perform_later(caller_number)
      end

      render xml: <<~TWIML
        <?xml version="1.0" encoding="UTF-8"?>
        <Response>
          <Hangup/>
        </Response>
      TWIML
    end

    private

    def validate_twilio_signature!
      return if Rails.env.development? && skip_validation_in_dev?

      auth_token = Rails.application.credentials.dig(:twilio, :auth_token) ||
                   ENV.fetch("TWILIO_AUTH_TOKEN", nil)

      unless auth_token.present?
        Rails.logger.warn("[Twilio::Voice] No auth token configured")
        head :forbidden
        return
      end

      validator = ::Twilio::Security::RequestValidator.new(auth_token)
      signature = request.headers["X-Twilio-Signature"]
      url = request.original_url
      params_hash = request.request_parameters

      unless validator.validate(url, params_hash, signature)
        Rails.logger.warn("[Twilio::Voice] Invalid Twilio signature")
        head :forbidden
      end
    end

    def skip_validation_in_dev?
      ENV["SKIP_TWILIO_VALIDATION"] == "true"
    end
  end
end
