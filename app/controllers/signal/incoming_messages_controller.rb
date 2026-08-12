module Signal
  class IncomingMessagesController < ActionController::Base
    skip_before_action :verify_authenticity_token
    before_action :validate_signature!

    def create
      ::Support::ProcessIncomingSignalMessage.call(params.to_unsafe_h)
      head :ok
    rescue => e
      Rails.logger.error("[Signal::IncomingMessages] #{e.class}: #{e.message}")
      head :internal_server_error
    end

    private

    def validate_signature!
      return if Rails.env.development? && skip_validation_in_dev?

      signature = request.headers["X-Signal-Signature"]
      timestamp = request.headers["X-Signal-Timestamp"]

      unless signature.present? && timestamp.present?
        Rails.logger.warn("[Signal::IncomingMessages] Missing signature or timestamp headers")
        head :forbidden
        return
      end

      timestamp_age = Time.current.to_i - timestamp.to_i
      if timestamp_age.abs > 300
        Rails.logger.warn("[Signal::IncomingMessages] Timestamp too old: #{timestamp_age}s")
        head :forbidden
        return
      end

      payload = request.raw_post

      unless SignalService.verify_webhook_signature(payload: payload, signature: signature, timestamp: timestamp)
        Rails.logger.warn("[Signal::IncomingMessages] Invalid signature")
        head :forbidden
      end
    end

    def skip_validation_in_dev?
      ENV["SKIP_SIGNAL_VALIDATION"] == "true"
    end
  end
end
