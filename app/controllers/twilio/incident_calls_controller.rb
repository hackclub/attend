module Twilio
  class IncidentCallsController < ActionController::Base
    skip_before_action :verify_authenticity_token
    before_action :validate_twilio_signature!
    before_action :set_incident_report

    # Initial greeting + acknowledgement menu.
    def voice
      response = ::Twilio::TwiML::VoiceResponse.new do |r|
        r.gather(num_digits: 1, action: gather_action_url, method: "POST", timeout: 10) do |g|
          g.say(message: greeting)
        end
        # Reached only if no key was pressed within the timeout.
        r.say(message: "We didn't receive a response. Goodbye.")
        r.hangup
      end

      render xml: response.to_s
    end

    # Handles the pressed digit.
    def gather
      digit = params["Digits"]

      if %w[1 2].exclude?(digit)
        return render xml: reprompt_twiml
      end

      names = @incident_report.record_acknowledgement!(name: acknowledger_name, phone: params["To"])
      ack_sentence = "#{names.to_sentence} acknowledged the incident."

      response = ::Twilio::TwiML::VoiceResponse.new do |r|
        r.say(message: ack_sentence)

        if digit == "1"
          r.say(message: "Incident acknowledged. Goodbye.")
        else
          r.say(message: more_info_message)
        end

        r.hangup
      end

      render xml: response.to_s
    end

    private

    def set_incident_report
      @incident_report = IncidentReport.find(params[:id])
    end

    def greeting
      "This is Attend. A new emergency incident report was created at #{@incident_report.event_name}. " \
        "Press 1 to acknowledge, or press 2 to hear more information."
    end

    def more_info_message
      "Category: #{@incident_report.incident_type_label}. " \
        "Summary: #{@incident_report.summary}. " \
        "Details: #{@incident_report.details}. " \
        "This incident has been acknowledged. Goodbye."
    end

    def reprompt_twiml
      ::Twilio::TwiML::VoiceResponse.new do |r|
        r.redirect(voice_action_url, method: "POST")
      end.to_s
    end

    # Name is passed through from the outbound call; fall back to the configured list, then the number.
    def acknowledger_name
      return params["name"] if params["name"].present?

      to = normalize(params["To"])
      match = Setting.incident_reports_emergency_phone_list.find { |e| normalize(e[:phone]) == to }
      match&.dig(:name) || params["To"]
    end

    def normalize(number)
      number.to_s.gsub(/[^\d]/, "")
    end

    def gather_action_url
      twilio_incident_gather_url(@incident_report, name: params["name"].presence, **public_url_opts)
    end

    def voice_action_url
      twilio_incident_voice_url(@incident_report, name: params["name"].presence, **public_url_opts)
    end

    def public_url_opts
      if ENV["TWILIO_PUBLIC_HOST"].present?
        { host: ENV["TWILIO_PUBLIC_HOST"], protocol: "https" }
      else
        { host: request.host_with_port, protocol: request.protocol.delete("://") }
      end
    end

    def validate_twilio_signature!
      return if Rails.env.development? && ENV["SKIP_TWILIO_VALIDATION"] == "true"

      auth_token = Rails.application.credentials.dig(:twilio, :auth_token) || ENV.fetch("TWILIO_AUTH_TOKEN", nil)

      unless auth_token.present?
        Rails.logger.warn("[Twilio::IncidentCalls] No auth token configured")
        head :forbidden
        return
      end

      validator = ::Twilio::Security::RequestValidator.new(auth_token)
      signature = request.headers["X-Twilio-Signature"]

      unless validator.validate(request.original_url, request.request_parameters, signature)
        Rails.logger.warn("[Twilio::IncidentCalls] Invalid Twilio signature")
        head :forbidden
      end
    end
  end
end
